package ai.oriveo.community.feature.chat

import androidx.compose.runtime.Composable
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
    /** "Test capability" for a rejected web template: opens this model's advanced page in this connection. */
    onNavigateToRelayModelAdvanced: (providerId: String, modelId: String) -> Unit = { _, _ -> },
    onNavigateToSkillEdit: () -> Unit = {},
    onNavigateToNoteDetail: (String) -> Unit = {},
    /**
     * Remote MCP: where the server management screen and the add-server flow live. Re-authorization
     * does not navigate; the chat side calls the entry point installed on `McpChatToolRunner.reauthorizer`.
     */
    onNavigateToMcpServers: () -> Unit = {},
    onNavigateToMcpAddServer: () -> Unit = {},
    viewModel: ChatViewModel = koinViewModel(),
) {
    ChatScreenContent(
        initialConversationId = initialConversationId,
        searchQuery = searchQuery,
        onBack = onBack,
        onNavigateToMemory = onNavigateToMemory,
        onNavigateToProviderSetup = onNavigateToProviderSetup,
        onNavigateToVoiceSettings = onNavigateToVoiceSettings,
        onNavigateToProviderDetail = onNavigateToProviderDetail,
        onNavigateToConnectionWebSearch = onNavigateToConnectionWebSearch,
        onNavigateToRelayModelAdvanced = onNavigateToRelayModelAdvanced,
        onNavigateToSkillEdit = onNavigateToSkillEdit,
        onNavigateToNoteDetail = onNavigateToNoteDetail,
        onNavigateToMcpServers = onNavigateToMcpServers,
        onNavigateToMcpAddServer = onNavigateToMcpAddServer,
        viewModel = viewModel,
    )
}
