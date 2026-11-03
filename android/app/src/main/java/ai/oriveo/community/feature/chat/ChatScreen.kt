package ai.oriveo.community.feature.chat

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import ai.oriveo.community.BuildConfig
import org.koin.androidx.compose.koinViewModel

@Composable
fun ChatScreen(
    initialConversationId: String? = null,
    searchQuery: String? = null,
    onNavigateToConnectionWebSearch: (providerId: String) -> Unit = {},
    onBack: () -> Unit,
    /** Non-null editItemId: "this is wrong" edits that memory item directly. */
    onNavigateToMemory: (editItemId: String?) -> Unit = {},
    onNavigateToProviderSetup: () -> Unit = {},
    onNavigateToVoiceSettings: () -> Unit = {},
    onNavigateToProviderDetail: (providerId: String) -> Unit = {},
    onNavigateToWebSearchFromChat: (conversationId: String?, oneTap: ai.oriveo.community.core.search.OneTapReuseTarget?) -> Unit = { _, _ -> },
    /** External search error card: service details (edit = custom service editor); stays on web search settings when the service is not on this device. */
    onNavigateToWebSearchService: (serviceId: String?, edit: Boolean) -> Unit = { _, _ -> },
    /** "Test capability" for a rejected web template: opens this model's advanced page in this connection. */
    onNavigateToRelayModelAdvanced: (providerId: String, modelId: String) -> Unit = { _, _ -> },
    onNavigateToSkillEdit: () -> Unit = {},
    onNavigateToSkills: () -> Unit = {},
    /** Used-skill card "View skill" (P4 contract 23). */
    onNavigateToSkillDetail: (skillId: String) -> Unit = {},
    onNavigateToNoteDetail: (String) -> Unit = {},
    /**
     * Remote MCP: where the server management screen and the add-server flow live. Re-authorization
     * does not navigate; the chat side calls the entry point installed on `McpChatToolRunner.reauthorizer`.
     */
    onNavigateToMcpServers: () -> Unit = {},
    onNavigateToMcpAddServer: () -> Unit = {},
    viewModel: ChatViewModel = koinViewModel(),
) {
    if (BuildConfig.DEBUG) {
        // Debug only: registers the displayed list and session id for instrumented tests to read; cleared when leaving the composition.
        DisposableEffect(viewModel) {
            ChatScreenDebugProbe.register(viewModel)
            onDispose { ChatScreenDebugProbe.unregister(viewModel) }
        }
    }
    ChatScreenContent(
        initialConversationId = initialConversationId,
        searchQuery = searchQuery,
        onBack = onBack,
        onNavigateToMemory = onNavigateToMemory,
        onNavigateToProviderSetup = onNavigateToProviderSetup,
        onNavigateToVoiceSettings = onNavigateToVoiceSettings,
        onNavigateToProviderDetail = onNavigateToProviderDetail,
        onNavigateToWebSearchFromChat = onNavigateToWebSearchFromChat,
        onNavigateToConnectionWebSearch = onNavigateToConnectionWebSearch,
        onNavigateToWebSearchService = onNavigateToWebSearchService,
        onNavigateToRelayModelAdvanced = onNavigateToRelayModelAdvanced,
        onNavigateToSkillEdit = onNavigateToSkillEdit,
        onNavigateToSkills = onNavigateToSkills,
        onNavigateToSkillDetail = onNavigateToSkillDetail,
        onNavigateToNoteDetail = onNavigateToNoteDetail,
        onNavigateToMcpServers = onNavigateToMcpServers,
        onNavigateToMcpAddServer = onNavigateToMcpAddServer,
        viewModel = viewModel,
    )
}
