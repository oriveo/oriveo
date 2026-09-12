package ai.oriveo.community.feature.home

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.animation.core.animateFloat
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.CreateNewFolder
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import ai.oriveo.community.core.provider.ModelDisplayLookup
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.testTag
import androidx.metrics.performance.PerformanceMetricsState
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.BuildConfig
import ai.oriveo.community.R
import ai.oriveo.community.feature.modelpicker.ModelPickerContext
import ai.oriveo.community.feature.modelpicker.ModelPickerSheet
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Folder
import ai.oriveo.community.core.provider.ModelSelectionUtils
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import ai.oriveo.community.core.model.Skill
import ai.oriveo.community.feature.skills.SkillChip
import ai.oriveo.community.ui.component.ConversationRow
import ai.oriveo.community.ui.component.OriveoEmptyState
import ai.oriveo.community.ui.component.OriveoSystemBarFadeLength

import ai.oriveo.community.ui.component.oriveoSystemBarFadingEdges
import ai.oriveo.community.ui.component.rootTabTopInset
import ai.oriveo.community.ui.theme.OriveoTheme
import ai.oriveo.community.ui.theme.opacity
import ai.oriveo.community.feature.home.folders.FolderColorPickerDialog
import ai.oriveo.community.feature.home.folders.FolderRow
import ai.oriveo.community.feature.home.folders.MoveToFolderSheet
import ai.oriveo.community.feature.home.homescreen.ConversationItem
import ai.oriveo.community.feature.home.homescreen.HomeConversationEmptyState
import ai.oriveo.community.feature.home.homescreen.HomeEditingToolbar
import ai.oriveo.community.feature.home.homescreen.HomeHeader
import ai.oriveo.community.feature.home.homescreen.NewChatBar
import ai.oriveo.community.feature.home.homescreen.RenameDialog
import ai.oriveo.community.feature.home.homescreen.SectionHeaderWithSelection
import ai.oriveo.community.feature.home.homescreen.V2SectionHeader
import ai.oriveo.community.feature.home.homescreen.homeGroupRowPosition
import ai.oriveo.community.feature.home.homescreen.homeGroupedRowSurface
import org.koin.androidx.compose.koinViewModel
import androidx.compose.foundation.layout.ime
import ai.oriveo.community.ui.component.liquidGlassTabBarReservedHeight
import ai.oriveo.community.feature.home.homescreen.homeSectionHeaderInsets
import ai.oriveo.community.feature.home.homescreen.homeGroupedCardSurface
import org.koin.compose.koinInject
import ai.oriveo.community.ui.util.findActivity
import java.net.URI

internal const val HOME_EARLIER_PAGE_SIZE = 10

/** Horizontal margin of the home list (hero, Notes and group cards share one vertical line); the density correction already maps logical widths one to one with iOS, so the same value is used */
internal val HOME_LIST_HORIZONTAL_PADDING = 20.dp

/** Spacing between sections (iOS conversationContent VStack spacing 22) */
internal val HOME_SECTION_SPACING = 22.dp

/** The search-results layout only applies once search is open and the query is non-blank; merely opening the field keeps folders and pinned items in place */
internal fun homeShowsSearchResults(isSearching: Boolean, query: String): Boolean =
    isSearching && query.isNotBlank()

/**
 * Decides the "no conversations yet / no results" empty state.
 * - Top-level conversations are only those with folderID IS NULL: when folders exist their rows are already
 *   rendered above, so "no conversations yet" must not be stacked on top of them;
 * - While search results lag behind the current input (debounce + query in flight) no "no results" verdict is
 *   drawn, otherwise every keystroke flashes the empty state first.
 */
internal fun homeShowsConversationEmptyState(
    initialContentLoaded: Boolean,
    hasProviders: Boolean,
    topLevelEmpty: Boolean,
    folderCount: Int,
    showingSearchResults: Boolean,
    searchInFlight: Boolean,
): Boolean = initialContentLoaded &&
    hasProviders &&
    topLevelEmpty &&
    !searchInFlight &&
    (showingSearchResults || folderCount == 0)
internal const val HOME_HEADER_ACTION_SPACING_DP = 8
internal const val HOME_HEADER_ACTION_BUTTON_SIZE_DP = 40
internal const val HOME_HEADER_ACTION_ICON_SIZE_DP = 20

internal data class HomeSectionDisplay(
    val conversations: List<Conversation>,
    val remainingCount: Int,
)

internal fun resolveHomeSectionDisplay(
    group: DateGroup,
    conversations: List<Conversation>,
    isEditing: Boolean,
    earlierDisplayCount: Int,
): HomeSectionDisplay {
    if (group != DateGroup.Earlier || isEditing) {
        return HomeSectionDisplay(
            conversations = conversations,
            remainingCount = 0,
        )
    }

    val displayConversations = conversations.take(earlierDisplayCount)
    return HomeSectionDisplay(
        conversations = displayConversations,
        remainingCount = (conversations.size - displayConversations.size).coerceAtLeast(0),
    )
}

internal fun groupConversationsByFolder(
    conversations: List<Conversation>,
): Map<String, List<Conversation>> = conversations
    .asSequence()
    .filter { !it.folderID.isNullOrBlank() }
    .groupBy { requireNotNull(it.folderID) }
    .mapValues { (_, folderConversations) ->
        folderConversations.sortedByDescending(Conversation::updatedAt)
    }

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun HomeScreen(
    onNavigateToChat: (conversationId: String?, searchQuery: String?) -> Unit = { _, _ -> },

    onNavigateToChatAndAutoSend: (conversationId: String) -> Unit = {},
    onNavigateToOnboarding: () -> Unit = {},
    onNavigateToProviderSetup: () -> Unit = {},
    onNavigateToProviderDetail: (providerID: String) -> Unit = {},
    onNavigateToFolderDetail: (folderID: String) -> Unit = {},
    onNavigateToSkills: () -> Unit = {},
    onNavigateToNotes: () -> Unit = {},
    viewModel: HomeViewModel = koinViewModel(),
) {

    val homeSkills by viewModel.homeSkills.collectAsStateWithLifecycle()
    val activeNoteCount by viewModel.activeNoteCount.collectAsStateWithLifecycle()
    val latestNoteTitle by viewModel.latestNoteTitle.collectAsStateWithLifecycle()
    val providers by viewModel.providers.collectAsStateWithLifecycle()
    val folders by viewModel.folders.collectAsStateWithLifecycle()
    val allConversations by viewModel.allConversations.collectAsStateWithLifecycle()
    val searchSnapshot by viewModel.searchResults.collectAsStateWithLifecycle()
    val searchResults = searchSnapshot.items
    val homeSections by viewModel.homeSections.collectAsStateWithLifecycle()
    val pinnedConversations by viewModel.pinnedConversations.collectAsStateWithLifecycle()

    val pinnedIds = remember(pinnedConversations) {
        pinnedConversations.mapTo(HashSet(pinnedConversations.size)) { it.id }
    }
    val initialContentLoaded by viewModel.initialContentLoaded.collectAsStateWithLifecycle()
    val streamingConvIds by viewModel.streamingConversationIds.collectAsStateWithLifecycle()
    val providersById = remember(providers) { providers.associateBy { it.id } }
    val modelDisplayLookup = remember(providers) { ModelDisplayLookup(providers) }
    val skillsById = remember(homeSkills) { homeSkills.associateBy { it.id } }

    val foldersById = remember(folders) { folders.associateBy { it.id } }
    val searchQuery by viewModel.searchQuery.collectAsStateWithLifecycle()
    val showingSearchResults = homeShowsSearchResults(viewModel.isSearching, searchQuery)
    // No "no results" verdict while results lag behind the input (debounce + DB query in flight); matches iOS searchInFlight
    val searchInFlight = showingSearchResults && searchSnapshot.query != searchQuery
    val visibleTopLevelConversations = remember(homeSections, pinnedConversations, searchResults, searchQuery, viewModel.isSearching) {
        if (homeShowsSearchResults(viewModel.isSearching, searchQuery)) {
            searchResults
        } else {

            pinnedConversations + homeSections.flatMap { it.conversations }
        }
    }
    val lastUsedModelRef by viewModel.lastUsedModelRef.collectAsStateWithLifecycle()
    val activeModelState by viewModel.activeModelState.collectAsStateWithLifecycle()

    val rawIsDark = ai.oriveo.community.ui.theme.LocalIsDarkTheme.current
    val v2Colors = if (rawIsDark) ai.oriveo.community.ui.theme.DarkV2OriveoColors
        else ai.oriveo.community.ui.theme.LightV2OriveoColors
    androidx.compose.runtime.CompositionLocalProvider(
        ai.oriveo.community.ui.theme.LocalOriveoColors provides v2Colors,
    ) {
    val colors = OriveoTheme.colors
    val isDark = rawIsDark
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val view = LocalView.current
    val metricsStateHolder = remember(view) { PerformanceMetricsState.getHolderForHierarchy(view) }
    var showNewFolderDialog by remember { mutableStateOf(false) }
    var showMoveSheet by remember { mutableStateOf(false) }
    var pendingMoveConversationIds by remember { mutableStateOf(emptyList<String>()) }
    var hasConversationInFolder by remember { mutableStateOf(false) }
    var folderToRename by remember { mutableStateOf<Folder?>(null) }
    var folderToDelete by remember { mutableStateOf<Folder?>(null) }
    var colorPickerFolder by remember { mutableStateOf<Folder?>(null) }
    var isHomeResumed by remember {
        mutableStateOf(lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
    }
    var reviewPolicyRevision by remember { mutableStateOf(0) }
    val conversationsByFolder = remember(allConversations) {
        groupConversationsByFolder(allConversations)
    }

    androidx.compose.runtime.DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                isHomeResumed = true
                viewModel.refreshActiveProviderIfNeeded()
            } else if (event == Lifecycle.Event.ON_PAUSE) {
                isHomeResumed = false
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    LaunchedEffect(initialContentLoaded) {
        if (initialContentLoaded) {
            viewModel.refreshActiveProviderIfNeededOnInitialLoad()
        }
    }

    val homeMetricsMode = when {
        viewModel.isEditing -> "editing"
        viewModel.isSearching && searchQuery.isNotBlank() -> "search_results"
        viewModel.isSearching -> "search"
        else -> "default"
    }
    DisposableEffect(metricsStateHolder, homeMetricsMode) {
        val state = metricsStateHolder.state
        state?.putState("home_mode", homeMetricsMode)

        onDispose {
            state?.removeState("home_mode")
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .testTag("home_screen"),
    ) {
        AuroraScreenBackground()

        val statusBarInset = rootTabTopInset()
        val navigationBarInset = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
        val listHorizontal = HOME_LIST_HORIZONTAL_PADDING
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .oriveoSystemBarFadingEdges(
                    topInset = statusBarInset,
                    bottomInset = navigationBarInset,
                ),
            // The header yields one extra fade length (iOS puts it 16pt below the safe area): the top fade band is
            // present even at rest, and a capsule placed right under the status bar has its upper half washed out
            // as if something were covering it
            contentPadding = PaddingValues(top = statusBarInset + OriveoSystemBarFadeLength),
        ) {
            // ── Masthead: centered brand + trailing capsule, followed by the centered greeting (a search field while searching) ──
            item(key = "header") {
                HomeHeader(
                    isSearching = viewModel.isSearching,
                    isEditing = viewModel.isEditing,
                    searchQuery = searchQuery,
                    hasConversations = visibleTopLevelConversations.isNotEmpty() || folders.isNotEmpty(),
                    isDark = isDark,
                    onSearchQueryChange = { viewModel.setSearchQuery(it) },
                    onToggleSearch = {
                        if (viewModel.isSearching) viewModel.exitSearch()
                        else viewModel.isSearching = true
                    },
                    onExitEdit = { viewModel.exitEditMode() },
                    onCreateFolder = {
                        // The header entry is unrelated to "move to folder": conversations left pending after the sheet closed must not be swept into the new folder
                        pendingMoveConversationIds = emptyList()
                        showNewFolderDialog = true
                    },
                )
            }

            if (!viewModel.isEditing) {
                if (providers.isEmpty() && initialContentLoaded) {

                    item(key = "empty_provider") {
                        OriveoEmptyState(
                            icon = Icons.Outlined.Inbox,
                            title = stringResource(R.string.home_no_provider_title),
                            description = stringResource(R.string.home_no_provider_description),
                            actionTitle = stringResource(R.string.add_provider),
                            onAction = onNavigateToProviderSetup,
                            modifier = Modifier
                                .padding(horizontal = listHorizontal)
                                .padding(top = 22.dp),
                        )
                    }
                } else {
                    // Block spacing per the design: greeting → hero 22, hero → Notes 14
                    item(key = "new_chat_bar") {
                        Box(modifier = Modifier.padding(top = 22.dp)) {
                            NewChatBar(
                                activeModel = activeModelState.activeModel,
                                hasProvider = providers.isNotEmpty(),
                                isDark = isDark,
                                heroText = viewModel.heroText,
                                onHeroTextChange = { viewModel.heroText = it },
                                isSendingFromHero = viewModel.isSendingFromHero,
                                isSearchActive = viewModel.isSearching,
                                onSend = {
                                    viewModel.sendFromHero(
                                        onConversationCreated = { id -> onNavigateToChat(id, null) },
                                        onConversationCreatedAutoSend = { id ->
                                            onNavigateToChatAndAutoSend(id)
                                        },
                                        onMissingProvider = onNavigateToProviderSetup,
                                    )
                                },
                                onModelSelect = { viewModel.showModelPicker = true },
                                onAddProvider = onNavigateToProviderSetup,
                            )
                        }
                    }

                    // Fixed Notes entry card (not a bottom tab): active note count + latest title
                    item(key = "notes_entry") {
                        ai.oriveo.community.feature.notes.HomeNotesEntryCard(
                            noteCount = activeNoteCount,
                            latestTitle = latestNoteTitle,
                            onClick = onNavigateToNotes,
                            modifier = Modifier
                                .padding(horizontal = listHorizontal)
                                .padding(top = 14.dp),
                        )
                    }
                }
            }

            // The list sits 26 below Notes; in edit mode the hero and Notes collapse and the list follows the greeting directly
            item(key = "list_top_gap") {
                Spacer(modifier = Modifier.height(26.dp))
            }

            if (providers.isNotEmpty()) {
                if (showingSearchResults) {
                    item(key = "search_header") {
                        V2SectionHeader(
                            title = stringResource(R.string.search_results),
                            count = searchResults.size,
                            modifier = Modifier
                                .padding(horizontal = listHorizontal)
                                .homeSectionHeaderInsets(),
                        )
                    }
                }

                if (!showingSearchResults) {
                    // Order shared across platforms: Folders (containers first) → Pinned → date groups; 22 between sections, 8 between folders
                    itemsIndexed(
                        items = folders,
                        key = { _, folder -> "folder_${folder.id}" },
                    ) { index, folder ->
                        val folderConversations = conversationsByFolder[folder.id].orEmpty()
                        val isLastFolder = index == folders.lastIndex

                        Box(
                            modifier = Modifier.padding(
                                start = listHorizontal,
                                end = listHorizontal,
                                bottom = if (isLastFolder) HOME_SECTION_SPACING else 8.dp,
                            ),
                        ) {
                            FolderRow(
                                folder = folder,
                                count = folderConversations.size,
                                isExpanded = viewModel.isFolderExpanded(folder.id),
                                onToggleExpanded = { viewModel.toggleFolderExpansion(folder.id) },
                                onViewAll = { onNavigateToFolderDetail(folder.id) },
                                onRename = { folderToRename = folder },
                                onChangeColor = { colorPickerFolder = folder },
                                onDelete = { folderToDelete = folder },
                            ) {
                                if (folderConversations.isEmpty()) {
                                    Column(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .homeGroupedCardSurface()
                                            .padding(horizontal = 16.dp, vertical = 24.dp),
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        verticalArrangement = Arrangement.spacedBy(OriveoTheme.spacing.xs),
                                    ) {
                                        Text(
                                            text = stringResource(R.string.empty_folder),
                                            style = OriveoTheme.typography.footnote,
                                            color = colors.textSecondary,
                                        )
                                        Text(
                                            text = stringResource(R.string.empty_folder_hint),
                                            style = OriveoTheme.typography.caption,
                                            color = colors.textTertiary,
                                            textAlign = TextAlign.Center,
                                        )
                                        HomeFolderNewChatButton(
                                            onClick = {
                                                viewModel.createConversationInFolder(folder.id) { conversationId ->
                                                    onNavigateToChat(conversationId, null)
                                                }
                                            },
                                        )
                                    }
                                } else {
                                    // The same group card as the main list, with no dividers inside
                                    Column(modifier = Modifier.homeGroupedCardSurface()) {
                                        folderConversations.forEach { conversation ->
                                            ConversationItem(
                                                conversation = conversation,
                                                providersById = providersById,
                                                modelDisplayLookup = modelDisplayLookup,
                                                skillsById = skillsById,
                                                isEditing = viewModel.isEditing,
                                                isSelected = viewModel.selectedIds.contains(conversation.id),
                                                isStreaming = conversation.id in streamingConvIds,
                                                isPinned = pinnedIds.contains(conversation.id),
                                                onToggleSelection = { viewModel.toggleSelection(conversation.id) },
                                                onClick = { onNavigateToChat(conversation.id, null) },
                                                onRename = { viewModel.conversationToRename = conversation },
                                                onCopy = { viewModel.copyLastMessage(conversation.id, context) },
                                                onShare = { viewModel.shareConversation(conversation.id, context) },
                                                onSelect = { viewModel.startEditingWithSelection(conversation.id) },
                                                onDelete = { viewModel.conversationToDelete = conversation },
                                                onTogglePin = { viewModel.togglePinConversation(conversation.id) },
                                                onMove = {
                                                    pendingMoveConversationIds = listOf(conversation.id)
                                                    hasConversationInFolder = conversation.folderID != null
                                                    showMoveSheet = true
                                                },
                                            )
                                        }
                                    }
                                    HomeFolderNewChatButton(
                                        modifier = Modifier.padding(start = 4.dp),
                                        onClick = {
                                            viewModel.createConversationInFolder(folder.id) { conversationId ->
                                                onNavigateToChat(conversationId, null)
                                            }
                                        },
                                    )
                                }
                            }
                        }
                    }

                    if (pinnedConversations.isNotEmpty()) {
                        item(key = "pinned_section_header") {
                            V2SectionHeader(
                                title = stringResource(R.string.pinned_section),
                                count = pinnedConversations.size,
                                modifier = Modifier
                                    .padding(horizontal = listHorizontal)
                                    .homeSectionHeaderInsets(),
                            )
                        }
                        itemsIndexed(
                            items = pinnedConversations,
                            key = { _, conversation -> "pinned_${conversation.id}" },
                            contentType = { _, _ -> "home_conversation" },
                        ) { index, conversation ->
                            Box(
                                modifier = Modifier
                                    .padding(horizontal = listHorizontal)
                                    .homeGroupedRowSurface(homeGroupRowPosition(index, pinnedConversations.size)),
                            ) {
                                ConversationItem(
                                    conversation = conversation,
                                    providersById = providersById,
                                    modelDisplayLookup = modelDisplayLookup,
                                    skillsById = skillsById,
                                    isEditing = viewModel.isEditing,
                                    isSelected = viewModel.selectedIds.contains(conversation.id),
                                    isStreaming = conversation.id in streamingConvIds,
                                    isPinned = true,
                                    onToggleSelection = { viewModel.toggleSelection(conversation.id) },
                                    onClick = { onNavigateToChat(conversation.id, null) },
                                    onRename = { viewModel.conversationToRename = conversation },
                                    onCopy = { viewModel.copyLastMessage(conversation.id, context) },
                                    onShare = { viewModel.shareConversation(conversation.id, context) },
                                    onSelect = { viewModel.startEditingWithSelection(conversation.id) },
                                    onDelete = { viewModel.conversationToDelete = conversation },
                                    onTogglePin = { viewModel.togglePinConversation(conversation.id) },
                                    folderName = conversation.folderID?.let { foldersById[it]?.name },
                                    onMove = {
                                        pendingMoveConversationIds = listOf(conversation.id)
                                        hasConversationInFolder = conversation.folderID != null
                                        showMoveSheet = true
                                    },
                                )
                            }
                        }
                        item(key = "pinned_section_gap") {
                            Spacer(modifier = Modifier.height(HOME_SECTION_SPACING))
                        }
                    }
                }

                if (
                    homeShowsConversationEmptyState(
                        initialContentLoaded = initialContentLoaded,
                        hasProviders = providers.isNotEmpty(),
                        topLevelEmpty = visibleTopLevelConversations.isEmpty(),
                        folderCount = folders.size,
                        showingSearchResults = showingSearchResults,
                        searchInFlight = searchInFlight,
                    )
                ) {
                    item(key = "empty_conversations") {
                        Box {
                            if (showingSearchResults) {
                                OriveoEmptyState(
                                    icon = Icons.Outlined.Inbox,
                                    title = stringResource(R.string.no_search_results),
                                    description = stringResource(R.string.try_adjusting_search_query),
                                    modifier = Modifier
                                        .padding(horizontal = listHorizontal)
                                        .padding(top = OriveoTheme.spacing.xxl),
                                )
                            } else {
                                // Matches iOS HomeConversationEmptyState: glowing gradient circle + bubble icon + title/subtitle
                                HomeConversationEmptyState(
                                    isDark = isDark,
                                    modifier = Modifier.padding(horizontal = listHorizontal),
                                )
                            }
                        }
                    }
                } else {
                    if (showingSearchResults) {
                        // Search results still look like one group card, but each hit is its own LazyColumn item: a
                        // user with thousands of conversations typing a frequent character must not compose and
                        // measure hundreds of rows synchronously in one frame.
                        itemsIndexed(
                            items = searchResults,
                            key = { _, conversation -> "search_${conversation.id}" },
                            contentType = { _, _ -> "home_conversation" },
                        ) { index, conversation ->
                            Box(
                                modifier = Modifier
                                    .padding(horizontal = listHorizontal)
                                    .homeGroupedRowSurface(homeGroupRowPosition(index, searchResults.size)),
                            ) {
                                ConversationItem(
                                    conversation = conversation,
                                    providersById = providersById,
                                    modelDisplayLookup = modelDisplayLookup,
                                    skillsById = skillsById,
                                    isEditing = viewModel.isEditing,
                                    isSelected = viewModel.selectedIds.contains(conversation.id),
                                    isStreaming = conversation.id in streamingConvIds,
                                    isPinned = pinnedIds.contains(conversation.id),
                                    onToggleSelection = { viewModel.toggleSelection(conversation.id) },
                                    onClick = { onNavigateToChat(conversation.id, searchQuery) },
                                    onRename = { viewModel.conversationToRename = conversation },
                                    onCopy = { viewModel.copyLastMessage(conversation.id, context) },
                                    onShare = { viewModel.shareConversation(conversation.id, context) },
                                    onSelect = {
                                        viewModel.startEditingWithSelection(conversation.id)
                                    },
                                    onDelete = { viewModel.conversationToDelete = conversation },
                                    onTogglePin = { viewModel.togglePinConversation(conversation.id) },
                                    folderName = conversation.folderID?.let { foldersById[it]?.name },
                                    onMove = {
                                        pendingMoveConversationIds = listOf(conversation.id)
                                        hasConversationInFolder = conversation.folderID != null
                                        showMoveSheet = true
                                    },
                                )
                            }
                        }
                    } else {
                        // Each date section renders as one card (no dividers inside), split into real LazyColumn items to
                        // keep virtualization (fixes first-frame jank on the home route). The old implementation put a
                        // whole section into a single item, so hundreds of conversations from the last 7 days were
                        // composed and measured synchronously on the first frame, with main-thread frames of up to ~13s.
                        homeSections.forEach { section ->
                            val sectionConversations = section.conversations
                            item(key = "section_header_${section.group.name}") {
                                val groupTitle = when (section.group) {
                                    DateGroup.Today -> stringResource(R.string.today)
                                    DateGroup.Yesterday -> stringResource(R.string.yesterday)
                                    DateGroup.PastSevenDays -> stringResource(R.string.past_7_days)
                                    DateGroup.Earlier -> stringResource(R.string.earlier)
                                }
                                val headerModifier = Modifier
                                    .padding(horizontal = listHorizontal)
                                    .homeSectionHeaderInsets()
                                if (viewModel.isEditing) {
                                    SectionHeaderWithSelection(
                                        title = groupTitle,
                                        count = sectionConversations.size,
                                        allSelected = viewModel.areAllSelected(sectionConversations),
                                        onToggle = { viewModel.toggleSectionSelection(sectionConversations) },
                                        modifier = headerModifier,
                                    )
                                } else {
                                    V2SectionHeader(
                                        title = groupTitle,
                                        count = sectionConversations.size,
                                        modifier = headerModifier,
                                    )
                                }
                            }
                            itemsIndexed(
                                items = sectionConversations,
                                key = { _, conversation -> "conv_${section.group.name}_${conversation.id}" },
                                contentType = { _, _ -> "home_conversation" },
                            ) { index, conversation ->
                                Box(
                                    modifier = Modifier
                                        .padding(horizontal = listHorizontal)
                                        .homeGroupedRowSurface(homeGroupRowPosition(index, sectionConversations.size)),
                                ) {
                                    ConversationItem(
                                        conversation = conversation,
                                        providersById = providersById,
                                        modelDisplayLookup = modelDisplayLookup,
                                        skillsById = skillsById,
                                        isEditing = viewModel.isEditing,
                                        isSelected = viewModel.selectedIds.contains(conversation.id),
                                        isStreaming = conversation.id in streamingConvIds,
                                        isPinned = pinnedIds.contains(conversation.id),
                                        onToggleSelection = { viewModel.toggleSelection(conversation.id) },
                                        onClick = { onNavigateToChat(conversation.id, null) },
                                        onRename = { viewModel.conversationToRename = conversation },
                                        onCopy = { viewModel.copyLastMessage(conversation.id, context) },
                                        onShare = { viewModel.shareConversation(conversation.id, context) },
                                        onSelect = {
                                            viewModel.startEditingWithSelection(conversation.id)
                                        },
                                        onDelete = { viewModel.conversationToDelete = conversation },
                                        onTogglePin = { viewModel.togglePinConversation(conversation.id) },
                                        onMove = {
                                            pendingMoveConversationIds = listOf(conversation.id)
                                            hasConversationInFolder = conversation.folderID != null
                                            showMoveSheet = true
                                        },
                                    )
                                }
                            }
                            if (section.group == DateGroup.Earlier && section.remainingCount > 0) {
                                item(key = "section_more_${section.group.name}") {
                                    HomeShowMoreButton(
                                        remainingCount = section.remainingCount,
                                        onClick = viewModel::loadMoreEarlier,
                                        modifier = Modifier
                                            .padding(horizontal = listHorizontal)
                                            .padding(top = 8.dp),
                                    )
                                }
                            }
                            item(key = "section_gap_${section.group.name}") {
                                Spacer(modifier = Modifier.height(HOME_SECTION_SPACING))
                            }
                        }
                    }
                }
            }

            item(key = "list_tail") {
                HomeListTailSpacer(isEditing = viewModel.isEditing)
            }
        }

        // Editing toolbar: slides in from the bottom with a fade, floating above the tab bar
        AnimatedVisibility(
            visible = viewModel.isEditing,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                // The content layer no longer consumes systemBars as a whole; the reserved height already includes the navigation bar, so the overlay lands above the floating tab bar
                .padding(bottom = liquidGlassTabBarReservedHeight() + 8.dp),
            enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
            exit = slideOutVertically(targetOffsetY = { it }) + fadeOut(),
        ) {
            HomeEditingToolbar(
                selectedCount = viewModel.selectedIds.size,
                allSelected = viewModel.areAllSelected(visibleTopLevelConversations),
                onToggleAll = {
                    if (viewModel.areAllSelected(visibleTopLevelConversations)) {
                        viewModel.deselectAll(visibleTopLevelConversations)
                    } else {
                        viewModel.selectAll(visibleTopLevelConversations)
                    }
                },
                onMove = {
                    pendingMoveConversationIds = viewModel.selectedIds.toList()
                    hasConversationInFolder = allConversations.any {
                        it.id in viewModel.selectedIds && it.folderID != null
                    }
                    showMoveSheet = true
                },
                onDelete = { viewModel.showBatchDeleteConfirm = true },
            )
        }
    }

    viewModel.conversationToRename?.let { conversation ->
        RenameDialog(
            currentTitle = conversation.title,
            onConfirm = { newTitle ->
                viewModel.renameConversation(conversation.id, newTitle)
                viewModel.conversationToRename = null
            },
            onDismiss = { viewModel.conversationToRename = null },
        )
    }

    viewModel.conversationToDelete?.let { conversation ->
        AlertDialog(
            onDismissRequest = { viewModel.conversationToDelete = null },
            title = { Text(stringResource(R.string.delete_conversation)) },
            text = { Text(stringResource(R.string.delete_conversation_confirm)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteConversation(conversation.id)
                        viewModel.conversationToDelete = null
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
                ) {
                    Text(stringResource(R.string.delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.conversationToDelete = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    if (viewModel.showBatchDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { viewModel.showBatchDeleteConfirm = false },
            title = { Text(stringResource(R.string.delete_conversations_title, viewModel.selectedIds.size)) },
            text = { Text(stringResource(R.string.delete_conversations_confirm, viewModel.selectedIds.size)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.showBatchDeleteConfirm = false
                        viewModel.deleteSelectedConversations()
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
                ) {
                    Text(stringResource(R.string.delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.showBatchDeleteConfirm = false }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    // ── Model Picker Sheet ──
    if (viewModel.showModelPicker) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { viewModel.showModelPicker = false },
            sheetState = sheetState,
            dragHandle = null,
            contentWindowInsets = { WindowInsets(0) },

            containerColor = ai.oriveo.community.ui.theme.OriveoTheme.colors.backgroundBase,
        ) {
            ModelPickerSheet(
                context = ModelPickerContext.Home,
                providers = providers,
                // Highlight the model actually shown on the pill: the stored reference may be stale (provider deleted / model retired) and resolved to something else
                activeProviderId = activeModelState.activeModel?.provider?.id ?: lastUsedModelRef?.providerID,
                activeModelId = activeModelState.activeModel?.model?.id ?: lastUsedModelRef?.modelID,
                onModelSelected = { providerId, modelId ->
                    viewModel.setActiveModel(providerId, modelId)
                },
                onEnableModel = { providerId, modelId ->
                    viewModel.enableModel(providerId, modelId)
                },
                onDismiss = { viewModel.showModelPicker = false },
            )
        }
    }

    if (showMoveSheet && pendingMoveConversationIds.isNotEmpty()) {
        MoveToFolderSheet(
            folders = folders,
            hasConversationsInFolder = hasConversationInFolder,
            onMoveToFolder = { folderId ->
                viewModel.moveConversationIdsToFolder(
                    ids = pendingMoveConversationIds,
                    folderID = folderId,
                    clearSelection = viewModel.isEditing,
                )
                pendingMoveConversationIds = emptyList()
                showMoveSheet = false
            },
            onRemoveFromFolder = {
                viewModel.moveConversationIdsToFolder(
                    ids = pendingMoveConversationIds,
                    folderID = null,
                    clearSelection = viewModel.isEditing,
                )
                pendingMoveConversationIds = emptyList()
                showMoveSheet = false
            },
            onCreateFolderRequest = {
                showMoveSheet = false
                showNewFolderDialog = true
            },
            onDismiss = {
                showMoveSheet = false
            },
        )
    }

    colorPickerFolder?.let { folder ->
        FolderColorPickerDialog(
            currentTag = folder.colorTag,
            onSelect = { tag -> viewModel.updateFolderColor(folder.id, tag) },
            onDismiss = { colorPickerFolder = null },
        )
    }

    if (showNewFolderDialog) {
        var folderName by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = {
                showNewFolderDialog = false
                if (pendingMoveConversationIds.isEmpty()) {
                    folderName = ""
                }
            },
            title = { Text(stringResource(R.string.new_folder)) },
            text = {
                OutlinedTextField(
                    value = folderName,
                    onValueChange = { folderName = it.take(30) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(stringResource(R.string.folder_name)) },
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val idsToMove = pendingMoveConversationIds
                        viewModel.createFolder(folderName) { createdFolder ->
                            if (idsToMove.isNotEmpty()) {
                                viewModel.moveConversationIdsToFolder(
                                    ids = idsToMove,
                                    folderID = createdFolder.id,
                                    clearSelection = viewModel.isEditing,
                                )
                            }
                        }
                        pendingMoveConversationIds = emptyList()
                        folderName = ""
                        showNewFolderDialog = false
                    },
                    enabled = folderName.isNotBlank(),
                ) {
                    Text(stringResource(R.string.create))
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        folderName = ""
                        pendingMoveConversationIds = emptyList()
                        showNewFolderDialog = false
                    },
                ) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    if (viewModel.showSkillProviderPrompt) {
        AlertDialog(
            onDismissRequest = viewModel::dismissSkillProviderPrompt,
            title = { Text(stringResource(R.string.skills_providerRequiredTitle)) },
            text = { Text(stringResource(R.string.skills_providerRequiredMessage)) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.dismissSkillProviderPrompt()
                    onNavigateToProviderSetup()
                }) {
                    Text(stringResource(R.string.skills_addProvider))
                }
            },
            dismissButton = {
                TextButton(onClick = viewModel::dismissSkillProviderPrompt) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    folderToRename?.let { folder ->
        var renameText by remember(folder.id) { mutableStateOf(folder.name) }
        AlertDialog(
            onDismissRequest = { folderToRename = null },
            title = { Text(stringResource(R.string.rename_folder)) },
            text = {
                OutlinedTextField(
                    value = renameText,
                    onValueChange = { renameText = it.take(30) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(stringResource(R.string.folder_name)) },
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.renameFolder(folder.id, renameText)
                        folderToRename = null
                    },
                    enabled = renameText.isNotBlank(),
                ) {
                    Text(stringResource(R.string.save))
                }
            },
            dismissButton = {
                TextButton(onClick = { folderToRename = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    folderToDelete?.let { folder ->
        AlertDialog(
            onDismissRequest = { folderToDelete = null },
            title = { Text(stringResource(R.string.delete_folder_title, folder.name)) },
            text = { Text(stringResource(R.string.delete_folder_confirm)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.deleteFolder(folder.id)
                        folderToDelete = null
                    },
                    colors = ButtonDefaults.textButtonColors(contentColor = colors.danger),
                ) {
                    Text(stringResource(R.string.delete_folder))
                }
            },
            dismissButton = {
                TextButton(onClick = { folderToDelete = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    }
}

/** "Show More (N)": 11sp semibold tertiary text, tappable across the full width (matches iOS earlierShowMoreButton). */
@Composable
private fun HomeShowMoreButton(
    remainingCount: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onClick)
            .padding(vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = stringResource(R.string.show_more, remainingCount),
            fontSize = 11.sp,
            lineHeight = 14.sp,
            fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
            color = OriveoTheme.colors.textTertiary,
        )
    }
}

/** The "+ New Chat" text button in an expanded folder. */
@Composable
private fun HomeFolderNewChatButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    TextButton(onClick = onClick, modifier = modifier) {
        Icon(
            imageVector = Icons.Outlined.Add,
            contentDescription = null,
            modifier = Modifier.size(14.dp),
        )
        Spacer(modifier = Modifier.size(4.dp))
        Text(stringResource(R.string.new_chat))
    }
}

/**
 * Tail spacer of the list: content runs under the navigation bar and the floating tab bar, so the last row must be
 * able to scroll above them; edit mode also leaves room for the toolbar. While the keyboard is up (search) it
 * yields the keyboard height, otherwise the last few results stay hidden behind it. The insets are read only
 * inside this item: the IME animation changes every frame, and reading it in the screen scope would recompose
 * the whole page frame by frame.
 */
@Composable
private fun HomeListTailSpacer(isEditing: Boolean) {
    val chrome = liquidGlassTabBarReservedHeight() + if (isEditing) 72.dp else 24.dp
    val ime = WindowInsets.ime.asPaddingValues().calculateBottomPadding() + 16.dp
    Spacer(modifier = Modifier.height(maxOf(chrome, ime)))
}

/**
 * Reduces a catalog base URL to the bare host (plus port, when one is given) for display.
 *
 * Returns an empty string when there is no URL to describe, which is a valid configuration: it
 * means the build fetches no model catalog. Callers are responsible for showing their own
 * localized placeholder in that case.
 */
internal fun resolveBackendDomainLabel(rawUrl: String): String {
    val trimmed = rawUrl.trim().trimEnd('/')
    if (trimmed.isEmpty()) {
        return ""
    }

    val parsed = runCatching { URI(trimmed) }.getOrNull()
    val host = parsed?.host?.takeIf { it.isNotBlank() }
    if (host != null) {
        return formatBackendHost(host, parsed.port)
    }

    val withoutScheme = trimmed.replace(Regex("^[a-zA-Z][a-zA-Z0-9+\\-.]*://"), "")
    return withoutScheme.substringBefore('/').ifBlank { trimmed }
}

private fun formatBackendHost(host: String, port: Int): String {
    val base = if (host.contains(':') && !host.startsWith("[")) "[$host]" else host
    return if (port > 0) "$base:$port" else base
}
