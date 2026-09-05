package ai.oriveo.community.feature.chat

import androidx.compose.runtime.Composable
import org.koin.androidx.compose.koinViewModel

@Composable
fun ChatScreen(
    initialConversationId: String? = null,
    searchQuery: String? = null,
    onBack: () -> Unit,
    onNavigateToMemory: () -> Unit = {},
    onNavigateToProviderSetup: () -> Unit = {},
    onNavigateToProviderDetail: (providerId: String) -> Unit = {},
    onNavigateToSkillEdit: () -> Unit = {},
    onNavigateToNoteDetail: (String) -> Unit = {},
    viewModel: ChatViewModel = koinViewModel(),
) {
    ChatScreenContent(
        initialConversationId = initialConversationId,
        searchQuery = searchQuery,
        onBack = onBack,
        onNavigateToMemory = onNavigateToMemory,
        onNavigateToProviderSetup = onNavigateToProviderSetup,
        onNavigateToProviderDetail = onNavigateToProviderDetail,
        onNavigateToSkillEdit = onNavigateToSkillEdit,
        onNavigateToNoteDetail = onNavigateToNoteDetail,
        viewModel = viewModel,
    )
}
