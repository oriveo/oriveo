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
    /** Settings memory page; when editItemId is non-null the edit screen for that item opens directly (the "this is wrong" action in chat). */
    @Serializable data class Memory(val editItemId: String? = null) : AppRoute
    /** Inbox of suggested memory candidates, entered from the row on the memory page. */
    @Serializable data object MemoryInbox : AppRoute
    @Serializable data object ContextSettings : AppRoute
    /** Settings > Theme (follow system, preview, light / dark palette swatches). */
    @Serializable data object ThemeSettings : AppRoute
    @Serializable data object VoiceSettings : AppRoute
    /** Remote MCP: the server list, adding a server, and a server's details. */
    @Serializable data object McpServers : AppRoute
    /** Settings > Web Search (my services, add, connect / custom, consent and test, and detail are all paged within this one route). */
    @Serializable data object WebSearchSettings : AppRoute
    /**
     * Opens web search settings from the chat web search card (external search contract): non-empty [serviceId] = one-tap enable; the connect page pre-fills per oneTapReuseTarget,
     * and once the test passes, the web switch of conversation [conversationId] is turned on; empty = the add-search-service flow, which does not auto-enable on return.
     */
    @Serializable data class WebSearchFromChat(
        /** Empty = the panel cannot persist, so a passed one-tap enable does not write the conversation's web setting. */
        val conversationId: String? = null,
        val serviceId: String? = null,
        val regionId: String? = null,
        val connectionRef: String? = null,
        val connectionName: String? = null,
    ) : AppRoute
    /**
     * Jump from the external search error card in chat (external search contract): the detail of [serviceId]; [edit] = go straight into custom service editing.
     * If the service is no longer on this device (or [serviceId] is empty), stay on the web search settings page.
     */
    @Serializable data class WebSearchService(
        val serviceId: String? = null,
        val edit: Boolean = false,
    ) : AppRoute
    @Serializable data object McpAddServer : AppRoute
    @Serializable data class McpServerDetail(val serverId: String) : AppRoute
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
        /** Pushes a subpage on entry: the chat model options "Open web settings" and the rejected-template "Test capability" link. */
        val initialLayer: String? = null,
        /** Which model's advanced page [LAYER_MODEL_ADVANCED] opens. */
        val initialModelID: String? = null,
    ) : AppRoute {
        companion object {
            const val LAYER_WEB_SEARCH = "web_search"
            const val LAYER_MODEL_ADVANCED = "model_advanced"
        }
    }

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
