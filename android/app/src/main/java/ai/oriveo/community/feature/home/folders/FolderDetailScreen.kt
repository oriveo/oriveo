package ai.oriveo.community.feature.home.folders

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.provider.ModelDisplayLookup
import ai.oriveo.community.core.util.normalizeUuid
import ai.oriveo.community.feature.home.HomeViewModel
import ai.oriveo.community.feature.home.resolveConversationModelName
import ai.oriveo.community.ui.component.ConversationRow
import ai.oriveo.community.ui.component.OriveoCard
import ai.oriveo.community.ui.component.OriveoEmptyState
import ai.oriveo.community.ui.theme.OriveoTheme
import org.koin.androidx.compose.koinViewModel

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun FolderDetailScreen(
    folderID: String,
    onNavigateToChat: (String) -> Unit,
    onNavigateBack: () -> Unit,
    viewModel: HomeViewModel = koinViewModel(),
) {

    @Suppress("NAME_SHADOWING")
    val folderID = normalizeUuid(folderID)
    val folders by viewModel.folders.collectAsStateWithLifecycle()
    val allConversations by viewModel.allConversations.collectAsStateWithLifecycle()
    val providers by viewModel.providers.collectAsStateWithLifecycle()
    val streamingConvIds by viewModel.streamingConversationIds.collectAsStateWithLifecycle()
    val contentLoaded by viewModel.initialContentLoaded.collectAsStateWithLifecycle()
    val folder = folders.firstOrNull { it.id == folderID }
    val providersById = remember(providers) { providers.associateBy { it.id } }
    val modelDisplayLookup = remember(providers) { ModelDisplayLookup(providers) }
    val screenH = OriveoTheme.layout.screenH
    var searchQuery by remember { mutableStateOf("") }

    val conversations = remember(allConversations, folderID, searchQuery) {
        allConversations
            .filter { it.folderID == folderID }
            .filter {
                if (searchQuery.isBlank()) {
                    true
                } else {
                    val query = searchQuery.lowercase()
                    it.title.lowercase().contains(query) || it.previewText.lowercase().contains(query)
                }
            }
            .sortedByDescending { it.updatedAt }
    }

    // On a fresh ViewModel's first frame, folders is still the stateIn initial emptyList, which does not mean the
    // folder is gone: wait for the first Room result, and go back only if folder is still null (deleted). Otherwise
    // the detail screen would bounce back to Home the moment it opens.
    LaunchedEffect(folder, contentLoaded) {
        if (folderDetailShouldNavigateBack(contentLoaded = contentLoaded, folderExists = folder != null)) {
            onNavigateBack()
        }
    }

    Scaffold(
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        text = folder?.name.orEmpty(),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.md),
        ) {
            item {
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = screenH),
                    singleLine = true,
                    placeholder = { Text(stringResource(R.string.search_in_folder)) },
                )
            }

            item {
                TextButton(
                    onClick = {
                        viewModel.createConversationInFolder(folderID) { conversationId ->
                            onNavigateToChat(conversationId)
                        }
                    },
                    modifier = Modifier.padding(horizontal = screenH),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Add,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp),
                    )
                    Spacer(modifier = Modifier.size(6.dp))
                    Text(stringResource(R.string.new_chat))
                }
            }

            if (conversations.isEmpty()) {
                item {
                    OriveoEmptyState(
                        icon = Icons.Outlined.Inbox,
                        title = stringResource(R.string.empty_folder),
                        description = stringResource(R.string.empty_folder_hint),
                        modifier = Modifier.padding(horizontal = screenH),
                    )
                }
            } else {
                items(conversations, key = { it.id }) { conversation ->
                    Box(modifier = Modifier.padding(horizontal = screenH)) {
                        FolderDetailConversationRow(
                            conversation = conversation,
                            providersById = providersById,
                            modelDisplayLookup = modelDisplayLookup,
                            isStreaming = conversation.id in streamingConvIds,
                            onClick = { onNavigateToChat(conversation.id) },
                        )
                    }
                }
            }

            item {
                Spacer(modifier = Modifier.size(OriveoTheme.spacing.xl))
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FolderDetailConversationRow(
    conversation: Conversation,
    providersById: Map<String, ai.oriveo.community.core.model.Provider>,
    modelDisplayLookup: ModelDisplayLookup,
    isStreaming: Boolean = false,
    onClick: () -> Unit,
) {
    val provider = providersById[conversation.providerID]

    val providerKind = conversation.providerKind
    val providerName = provider?.displayName ?: providerKind.displayName
    val modelName = remember(conversation.modelID, provider, modelDisplayLookup) {
        resolveConversationModelName(
            conversation = conversation,
            provider = provider,
            displayLookup = modelDisplayLookup,
        )
    }

    // The row already shows the title: no extra "folder icon + title" line on top (it used to read every title twice on two lines)
    OriveoCard(
        modifier = Modifier.combinedClickable(
            onClick = onClick,
            onLongClick = onClick,
        ),
        radius = 16.dp,
        contentPadding = androidx.compose.foundation.layout.PaddingValues(0.dp),
    ) {
        ConversationRow(
            conversation = conversation,
            providerKind = providerKind,
            providerName = providerName,
            modelName = modelName,
            relayKind = provider?.relayKind,
            isStreaming = isStreaming,
        )
    }
}

/** When folder detail navigates back on its own: only once content has loaded and the folder still does not exist. */
internal fun folderDetailShouldNavigateBack(contentLoaded: Boolean, folderExists: Boolean): Boolean =
    contentLoaded && !folderExists
