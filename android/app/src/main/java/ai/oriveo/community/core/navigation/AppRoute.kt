package ai.oriveo.community.core.navigation

import kotlinx.serialization.Serializable

@Serializable
enum class ProviderSetupEntryPoint {
    Onboarding,
    Providers,
    SkillEdit,
}

@Serializable
enum class ManualModelEntryContext {
    Onboarding,
    Providers,
    ProviderDetail,
    SkillEdit,
}

/** Navigation routes. */
sealed interface AppRoute {

    @Serializable data object Home : AppRoute
    @Serializable data object Providers : AppRoute
    @Serializable data object Settings : AppRoute

    @Serializable
    data class Chat(
        val conversationId: String? = null,
        val searchQuery: String? = null,
        val autoSend: Boolean = false,
        val focusMessageId: String? = null,
        val fromNoteId: String? = null,
    ) : AppRoute

    @Serializable data class FolderDetail(val folderID: String) : AppRoute
    @Serializable data object Notes : AppRoute
    @Serializable data class NoteDetail(val noteID: String) : AppRoute
    @Serializable data object Memory : AppRoute
    @Serializable data object Onboarding : AppRoute

    @Serializable
    data class ProviderSetup(
        val entryPoint: ProviderSetupEntryPoint = ProviderSetupEntryPoint.Onboarding,
        val preselectedKind: ai.oriveo.community.core.model.ProviderKind? = null,
    ) : AppRoute

    @Serializable
    data class ProviderDetail(
        val providerID: String,
        val entryPoint: ProviderSetupEntryPoint? = null,
    ) : AppRoute

    @Serializable
    data class ManualModelEntry(
        val providerID: String,
        val context: ManualModelEntryContext = ManualModelEntryContext.Providers,
    ) : AppRoute

    @Serializable
    data class RelaySetup(
        val entryPoint: ProviderSetupEntryPoint = ProviderSetupEntryPoint.Onboarding,
    ) : AppRoute

    @Serializable
    data class LocalComputeSetup(
        val entryPoint: ProviderSetupEntryPoint = ProviderSetupEntryPoint.Onboarding,
    ) : AppRoute

    @Serializable data object Backup : AppRoute
    @Serializable data object Skills : AppRoute
    @Serializable data class SkillEdit(val skillId: String? = null) : AppRoute
}
