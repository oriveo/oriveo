package ai.oriveo.community.feature.settings

enum class MemoryScreenMode {
    Starter,
    Items,
}

enum class MemoryScreenAction {
    GenerateDraft,
    AddItem,
}

/**
 * Hero visual style.
 *
 * - [DraftStarter]: no items yet but there are recent conversations to analyze; "Draft with AI" is the secondary button.
 * - [ManualStarter]: no items and no recent conversations; only "Add".
 * - [ActiveMemory]: items exist; the hero switches to the "ready" form.
 */
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
    val showsSupportSections: Boolean,
)

/** Empty state: "Add" is the primary button and, with recent conversations, "Draft with AI" is secondary; once items exist the hero keeps only "Draft with AI". */
fun buildMemoryScreenPresentation(
    hasItems: Boolean,
    hasRecentConversations: Boolean,
): MemoryScreenPresentation {
    if (!hasItems) {
        return MemoryScreenPresentation(
            mode = MemoryScreenMode.Starter,
            heroStyle = if (hasRecentConversations) MemoryHeroStyle.DraftStarter else MemoryHeroStyle.ManualStarter,
            primaryAction = MemoryScreenAction.AddItem,
            secondaryAction = if (hasRecentConversations) MemoryScreenAction.GenerateDraft else null,
            showsSupportSections = false,
        )
    }

    return MemoryScreenPresentation(
        mode = MemoryScreenMode.Items,
        heroStyle = MemoryHeroStyle.ActiveMemory,
        // Drafting from recent conversations stays available once items exist; the result prefills a new editor, and if an editor is open while generating we ask before replacing it.
        primaryAction = if (hasRecentConversations) MemoryScreenAction.GenerateDraft else null,
        secondaryAction = null,
        showsSupportSections = true,
    )
}
