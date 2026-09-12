package ai.oriveo.community.core.navigation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.core.tween
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import androidx.metrics.performance.PerformanceMetricsState
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavDestination
import androidx.navigation.NavDestination.Companion.hasRoute
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.toRoute
import ai.oriveo.community.R
import ai.oriveo.community.core.app.AppViewModel
import ai.oriveo.community.core.reachability.ServiceReachabilityMonitor
import org.koin.compose.koinInject
import ai.oriveo.community.feature.backup.BackupScreen
import ai.oriveo.community.feature.chat.ChatScreen
import ai.oriveo.community.feature.home.AuroraScreenBackground
import ai.oriveo.community.feature.home.HomeScreen
import ai.oriveo.community.feature.home.folders.FolderDetailScreen
import ai.oriveo.community.feature.notes.NoteDetailScreen
import ai.oriveo.community.feature.notes.NotesScreen
import ai.oriveo.community.feature.onboarding.OnboardingViewModel
import ai.oriveo.community.feature.onboarding.OnboardingFlowScreen
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import org.koin.androidx.compose.koinViewModel
import ai.oriveo.community.feature.providers.ProvidersScreen
import ai.oriveo.community.feature.providers.ProvidersScreenBackground
import ai.oriveo.community.feature.providers.detail.ProviderDetailScreen
import ai.oriveo.community.feature.providers.manual.ManualModelEntryScreen
import ai.oriveo.community.feature.providers.relay.RelaySetupCompletionTarget
import ai.oriveo.community.feature.providers.relay.RelaySetupScreen
import ai.oriveo.community.feature.providers.CustomLLMConnectionMethod
import ai.oriveo.community.feature.providers.setup.ProviderSetupScreen
import ai.oriveo.community.feature.settings.MemoryScreen
import ai.oriveo.community.feature.settings.SettingsScreen
import ai.oriveo.community.feature.skills.SkillEditScreen
import ai.oriveo.community.feature.skills.SkillsListScreen
import ai.oriveo.community.ui.component.GlobalToastHost
import ai.oriveo.community.ui.component.LocalRootTabTopInset
import ai.oriveo.community.ui.component.LiquidGlassTabBar
import ai.oriveo.community.ui.component.LiquidGlassTabBarItem
import ai.oriveo.community.ui.component.OriveoTabGlyph
import ai.oriveo.community.ui.component.liquidGlassBlurSupported
import ai.oriveo.community.ui.component.liquidGlassTabBarBottomGap
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import ai.oriveo.community.ui.theme.OriveoColors
import ai.oriveo.community.ui.theme.OriveoScreenBackground
import ai.oriveo.community.core.performance.PageTrace
import ai.oriveo.community.ui.theme.OriveoTheme

/** Bottom navigation tab: one entry per root route, sharing its glyph set with the iOS tab bar. */
private data class TabItem(
    val labelRes: Int,
    val glyph: OriveoTabGlyph,
    val route: AppRoute,
)

private val tabs = listOf(
    TabItem(labelRes = R.string.tab_home, glyph = OriveoTabGlyph.Home, route = AppRoute.Home),
    TabItem(labelRes = R.string.tab_providers, glyph = OriveoTabGlyph.Providers, route = AppRoute.Providers),
    TabItem(labelRes = R.string.tab_settings, glyph = OriveoTabGlyph.Settings, route = AppRoute.Settings),
)

/**
 * Selected label color. The iOS system tab bar renders its tint (purple for Home, teal for Providers,
 * orange for Settings) vibrantly against the glass: brighter in dark mode, deeper in light mode. These
 * are the colors measured from that rendering rather than the raw tint values.
 */
internal fun tabSelectedLabelColor(route: AppRoute, isDark: Boolean): Color = when (route) {
    AppRoute.Providers -> if (isDark) Color(0xFF4CFFF2) else Color(0xFF007E75)
    AppRoute.Settings -> if (isDark) Color(0xFFFFBB64) else Color(0xFFDE3D00)
    else -> if (isDark) Color(0xFFD2B3FF) else Color(0xFF7442EE)
}

private fun NavDestination.tabIndex(): Int = tabs.indexOfFirst { hasRoute(it.route::class) }

private fun isTabSwitch(from: NavDestination, to: NavDestination): Boolean = from.tabIndex() >= 0 && to.tabIndex() >= 0

/** Full-screen routes that hide the bottom bar. */
private val fullScreenRoutes = setOf(
    AppRoute.Chat::class,
    AppRoute.FolderDetail::class,
    AppRoute.Notes::class,
    AppRoute.NoteDetail::class,
    AppRoute.Onboarding::class,
    AppRoute.ProviderSetup::class,
    AppRoute.ProviderDetail::class,
    AppRoute.ManualModelEntry::class,
    AppRoute.RelaySetup::class,
    AppRoute.LocalComputeSetup::class,
    AppRoute.Memory::class,
    AppRoute.Backup::class,
    AppRoute.Skills::class,
    AppRoute.SkillEdit::class,
)

internal fun traceNameForTab(route: AppRoute): String = when (route) {
    AppRoute.Home -> "Home"
    AppRoute.Providers -> "Providers"
    AppRoute.Settings -> "Settings"
    else -> "Unknown"
}

internal fun navHostRootChromeColor(colors: OriveoColors): Color = colors.background

@Composable
private fun HomeRootChromeBackground(
    isHomeRoute: Boolean,
    isProvidersRoute: Boolean,
    isSettingsRoute: Boolean,
) {

    when {
        isProvidersRoute -> ProvidersScreenBackground()
        isSettingsRoute -> OriveoScreenBackground()
        isHomeRoute -> AuroraScreenBackground()
        else -> Box(
            modifier = Modifier
                .fillMaxSize()
                .background(navHostRootChromeColor(OriveoTheme.colors)),
        )
    }
}

@OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
@Composable
fun OriveoNavHost(
    appViewModel: AppViewModel,
    hasCompletedOnboarding: Boolean,
) {
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = navBackStackEntry?.destination
    val view = LocalView.current
    val metricsStateHolder = remember(view) { PerformanceMetricsState.getHolderForHierarchy(view) }
    val reachabilityMonitor: ServiceReachabilityMonitor = koinInject()
    val reachabilityBannerState by reachabilityMonitor.bannerState.collectAsStateWithLifecycle()

    // On the first frame (cold start / Activity recreation) the back stack has not settled and the
    // destination is null. Hide the bar then, otherwise it flashes over the chat or onboarding screen
    // before fading out, and can even be tapped in the meantime.
    val shouldShowBottomBar by remember(currentDestination) {
        derivedStateOf {
            currentDestination?.let { dest ->
                fullScreenRoutes.none { dest.hasRoute(it) }
            } ?: false
        }
    }
    // The selected item only follows tab routes: during the 180ms fade-out when entering a full-screen
    // page it keeps the previous selection instead of sliding back to Home.
    var lastTabIndex by remember { mutableIntStateOf(0) }
    LaunchedEffect(currentDestination) {
        val index = currentDestination?.tabIndex() ?: -1
        if (index >= 0) lastTabIndex = index
    }
    val usesHomeRootChrome = currentDestination?.hasRoute(AppRoute.Home::class) ?: hasCompletedOnboarding
    val isProvidersRoute = currentDestination?.hasRoute(AppRoute.Providers::class) ?: false
    val isSettingsRoute = currentDestination?.hasRoute(AppRoute.Settings::class) ?: false
    // The chat screen reports connection problems inline on the failing message, so a banner over
    // the top of it would say the same thing twice.
    val suppressReachabilityBanner = currentDestination?.hasRoute(AppRoute.Chat::class) ?: false

    LaunchedEffect(appViewModel, navController) {
        kotlinx.coroutines.flow.emptyFlow<Any>().collect {
            navController.navigate(AppRoute.Home) {
                popUpTo(navController.graph.findStartDestination().id) {
                    inclusive = false
                }
                launchSingleTop = true
            }
        }
    }

    LaunchedEffect(metricsStateHolder, currentDestination) {
        metricsStateHolder.state?.putState("route", currentRouteLabel(currentDestination))
    }

    LaunchedEffect(Unit) {
        PageTrace.end("AppLaunch", detail = currentRouteLabel(currentDestination))
    }

    var topChromeHeightPx by remember { mutableIntStateOf(0) }
    val statusBarInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    val density = LocalDensity.current
    val remainingTopInset = with(density) {
        (statusBarInset.toPx() - topChromeHeightPx).coerceAtLeast(0f).toDp()
    }

    // Backdrop source for the floating glass tab bar: the root background and the NavHost content are
    // recorded into one layer, and the bar samples and blurs that layer from outside, so it never
    // captures itself.
    val tabBarHazeState = rememberHazeState(blurEnabled = liquidGlassBlurSupported())

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .semantics { testTagsAsResourceId = true }
        ) {
            // Backdrop layer: the root background and the content layer both live in here; the floating
            // tab bar (a sibling node) samples this layer for its glass blur.
            Box(modifier = Modifier.fillMaxSize().hazeSource(tabBarHazeState)) {
            // The root background must fill the edge-to-edge window. Home uses its own aurora gradient;
            // otherwise the status and navigation bar areas would show the global theme color as a seam.
            HomeRootChromeBackground(
                isHomeRoute = usesHomeRootChrome,
                isProvidersRoute = isProvidersRoute,
                isSettingsRoute = isSettingsRoute,
            )

            Box(modifier = Modifier.fillMaxSize()) {

                CompositionLocalProvider(LocalRootTabTopInset provides remainingTopInset) {
                Column(modifier = Modifier.fillMaxSize()) {

                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .onSizeChanged { topChromeHeightPx = it.height },
                    ) {

                        if (!suppressReachabilityBanner) {

                            ServiceReachabilityBanner(
                                state = reachabilityBannerState,
                                onDismiss = { reachabilityMonitor.dismissCurrentBanner() },
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .statusBarsPadding(),
                            )
                        }

                    }
                    NavHost(
                        navController = navController,
                        startDestination = if (hasCompletedOnboarding) AppRoute.Home else AppRoute.Onboarding,
                        modifier = Modifier
                            .fillMaxWidth()
                            .weight(1f),
                        // Switch between tabs instantly: the default 700ms cross-fade is far slower than the
                        // lens slide, ghosts both pages and composites two layers per frame. Entering or
                        // leaving a full-screen page keeps the default NavHost fade.
                        enterTransition = {
                            if (isTabSwitch(initialState.destination, targetState.destination)) EnterTransition.None
                            else fadeIn(animationSpec = tween(700))
                        },
                        exitTransition = {
                            if (isTabSwitch(initialState.destination, targetState.destination)) ExitTransition.None
                            else fadeOut(animationSpec = tween(700))
                        },
                    ) {

            composable<AppRoute.Home> {

                LaunchedEffect(Unit) { PageTrace.end("Home") }
                HomeScreen(
                    onNavigateToChat = { id, searchQuery ->
                        PageTrace.begin("Chat")
                        navController.navigate(
                            AppRoute.Chat(
                                conversationId = id,
                                searchQuery = searchQuery,
                            ),
                        )
                    },
                    onNavigateToChatAndAutoSend = { id ->
                        PageTrace.begin("Chat")
                        navController.navigate(
                            AppRoute.Chat(
                                conversationId = id,
                                autoSend = true,
                            ),
                        )
                    },
                    onNavigateToOnboarding = {
                        PageTrace.begin("Welcome")
                        navController.navigate(AppRoute.Onboarding)
                    },
                    onNavigateToProviderSetup = {
                        PageTrace.begin("ProviderSetup")
                        navController.navigate(AppRoute.ProviderSetup(ProviderSetupEntryPoint.Providers))
                    },
                    onNavigateToProviderDetail = { providerID ->
                        PageTrace.begin("ProviderDetail")
                        navController.navigate(AppRoute.ProviderDetail(providerID))
                    },
                    onNavigateToFolderDetail = { folderID ->
                        PageTrace.begin("FolderDetail")
                        navController.navigate(AppRoute.FolderDetail(folderID))
                    },
                    onNavigateToSkills = {
                        PageTrace.begin("Skills")
                        navController.navigate(AppRoute.Skills)
                    },
                    onNavigateToNotes = {
                        PageTrace.begin("Notes")
                        navController.navigate(AppRoute.Notes)
                    },
                )
            }
            composable<AppRoute.Providers> {
                LaunchedEffect(Unit) { PageTrace.end("Providers") }
                ProvidersScreen(
                    onNavigateToSetup = {
                        PageTrace.begin("ProviderSetup")
                        navController.navigate(AppRoute.ProviderSetup(ProviderSetupEntryPoint.Providers))
                    },
                    onNavigateToDetail = { providerID ->
                        PageTrace.begin("ProviderDetail")
                        navController.navigate(AppRoute.ProviderDetail(providerID))
                    },
                )
            }
            composable<AppRoute.Settings> {
                LaunchedEffect(Unit) { PageTrace.end("Settings") }
                SettingsScreen(
                    onNavigateToMemory = {
                        PageTrace.begin("Memory")
                        navController.navigate(AppRoute.Memory)
                    },
                    onNavigateToBackup = {
                        PageTrace.begin("Backup")
                        navController.navigate(AppRoute.Backup)
                    },
                    onNavigateToSkills = {
                        PageTrace.begin("Skills")
                        navController.navigate(AppRoute.Skills)
                    },
                )
            }

            composable<AppRoute.Chat> { backStackEntry ->
                val route = backStackEntry.toRoute<AppRoute.Chat>()
                LaunchedEffect(Unit) { PageTrace.end("Chat") }
                ChatScreen(
                    initialConversationId = route.conversationId,
                    searchQuery = route.searchQuery,
                    onBack = { navController.popBackStack() },
                    onNavigateToMemory = {
                        PageTrace.begin("Memory")
                        navController.navigate(AppRoute.Memory)
                    },
                    onNavigateToProviderSetup = {
                        PageTrace.begin("ProviderSetup")
                        navController.navigate(AppRoute.ProviderSetup(ProviderSetupEntryPoint.Providers))
                    },
                    onNavigateToProviderDetail = { providerID ->
                        PageTrace.begin("ProviderDetail")
                        navController.navigate(AppRoute.ProviderDetail(providerID))
                    },
                    onNavigateToSkillEdit = {

                        navController.navigate(AppRoute.SkillEdit())
                    },
                    onNavigateToNoteDetail = { noteID ->
                        PageTrace.begin("NoteDetail")
                        navController.navigate(AppRoute.NoteDetail(noteID))
                    },
                )
            }
            composable<AppRoute.FolderDetail> { backStackEntry ->
                val route = backStackEntry.toRoute<AppRoute.FolderDetail>()
                LaunchedEffect(Unit) { PageTrace.end("FolderDetail") }
                FolderDetailScreen(
                    folderID = route.folderID,
                    onNavigateToChat = { conversationId ->
                        PageTrace.begin("Chat")
                        navController.navigate(AppRoute.Chat(conversationId = conversationId))
                    },
                    onNavigateBack = { navController.popBackStack() },
                )
            }
            composable<AppRoute.Notes> {
                LaunchedEffect(Unit) { PageTrace.end("Notes") }
                NotesScreen(
                    onNavigateBack = { navController.popBackStack() },
                    onNavigateToNoteDetail = { noteID ->
                        PageTrace.begin("NoteDetail")
                        navController.navigate(AppRoute.NoteDetail(noteID))
                    },
                )
            }
            composable<AppRoute.NoteDetail> { backStackEntry ->
                val route = backStackEntry.toRoute<AppRoute.NoteDetail>()
                LaunchedEffect(Unit) { PageTrace.end("NoteDetail") }
                NoteDetailScreen(
                    noteID = route.noteID,
                    onNavigateBack = { navController.popBackStack() },
                    onNavigateToSource = { conversationId, messageId ->

                        PageTrace.begin("Chat")
                        navController.navigate(
                            AppRoute.Chat(
                                conversationId = conversationId,
                                focusMessageId = messageId,
                                fromNoteId = route.noteID,
                            ),
                        )
                    },
                    onNavigateToNoteDetail = { noteId ->
                        PageTrace.begin("NoteDetail")
                        navController.navigate(AppRoute.NoteDetail(noteId))
                    },
                )
            }
            composable<AppRoute.Onboarding> {
                LaunchedEffect(Unit) { PageTrace.end("Welcome") }
                val onboardingViewModel: OnboardingViewModel = koinViewModel()
                val onboardingContext = LocalContext.current
                val onboardingReduceMotion = remember(onboardingContext) {
                    isReduceMotionEnabled(onboardingContext)
                }
                OnboardingFlowScreen(
                    reduceMotion = onboardingReduceMotion,
                    onActViewed = {},
                    onSkipUsed = {},
                    onGetStarted = {
                        onboardingViewModel.completeOnboarding()
                        PageTrace.begin("Home")
                        navController.navigate(AppRoute.Home) {
                            popUpTo(navController.graph.findStartDestination().id) {
                                inclusive = true
                            }
                            launchSingleTop = true
                        }
                    },
                )
            }
            composable<AppRoute.ProviderSetup> { backStackEntry ->
                val route = backStackEntry.toRoute<AppRoute.ProviderSetup>()
                LaunchedEffect(Unit) { PageTrace.end("ProviderSetup") }
                ProviderSetupScreen(
                    entryPoint = route.entryPoint,
                    preselectedKind = route.preselectedKind,
                    onOpenRelaySetup = {
                        PageTrace.begin("RelaySetup")
                        navController.navigate(AppRoute.RelaySetup(route.entryPoint))
                    },
                    onOpenLocalComputeSetup = {
                        PageTrace.begin("LocalComputeSetup")
                        navController.navigate(AppRoute.LocalComputeSetup(route.entryPoint))
                    },
                    onManageExistingProvider = { providerID ->
                        PageTrace.begin("ProviderDetail")
                        navController.navigate(AppRoute.ProviderDetail(providerID, route.entryPoint))
                    },
                    onProviderRegistered = {
                        when (route.entryPoint) {
                            ProviderSetupEntryPoint.Onboarding -> {
                                PageTrace.begin("Home")
                                navController.navigate(AppRoute.Home) {
                                    popUpTo(navController.graph.findStartDestination().id) {
                                        inclusive = true
                                    }
                                    launchSingleTop = true
                                }
                                PageTrace.begin("Chat")
                                navController.navigate(AppRoute.Chat())
                            }
                            ProviderSetupEntryPoint.Providers -> {
                                navController.popBackStack()
                            }
                            ProviderSetupEntryPoint.SkillEdit -> {
                                navController.popBackStack()
                            }
                        }
                    },
                    onBack = { navController.popBackStack() },
                )
            }
            composable<AppRoute.ProviderDetail> { backStackEntry ->
                val route = backStackEntry.toRoute<AppRoute.ProviderDetail>()
                LaunchedEffect(Unit) { PageTrace.end("ProviderDetail") }
                ProviderDetailScreen(
                    onBack = { navController.popBackStack() },
                    onStartChat = { providerID, modelID ->
                        appViewModel.setActiveModel(providerID, modelID)
                        PageTrace.begin("Chat")
                        navController.navigate(AppRoute.Chat())
                    },
                    manualEntryContext = when (route.entryPoint) {
                        ProviderSetupEntryPoint.Onboarding -> ManualModelEntryContext.Onboarding
                        ProviderSetupEntryPoint.SkillEdit -> ManualModelEntryContext.SkillEdit
                        ProviderSetupEntryPoint.Providers,
                        null -> ManualModelEntryContext.ProviderDetail
                    },
                    onNavigateToManualEntry = { providerID ->
                        PageTrace.begin("ManualModelEntry")
                        navController.navigate(
                            AppRoute.ManualModelEntry(
                                providerID = providerID,
                                context = when (route.entryPoint) {
                                    ProviderSetupEntryPoint.Onboarding -> ManualModelEntryContext.Onboarding
                                    ProviderSetupEntryPoint.SkillEdit -> ManualModelEntryContext.SkillEdit
                                    ProviderSetupEntryPoint.Providers,
                                    null -> ManualModelEntryContext.ProviderDetail
                                },
                            ),
                        )
                    },
                )
            }
            composable<AppRoute.ManualModelEntry> { backStackEntry ->
                val route = backStackEntry.toRoute<AppRoute.ManualModelEntry>()
                LaunchedEffect(Unit) { PageTrace.end("ManualModelEntry") }
                ManualModelEntryScreen(
                    onBack = { navController.popBackStack() },
                    onCompleted = {
                        when (route.context) {
                            ManualModelEntryContext.Onboarding -> {
                                PageTrace.begin("Home")
                                navController.navigate(AppRoute.Home) {
                                    popUpTo(navController.graph.findStartDestination().id) {
                                        inclusive = true
                                    }
                                    launchSingleTop = true
                                }
                                PageTrace.begin("Chat")
                                navController.navigate(AppRoute.Chat())
                            }
                            ManualModelEntryContext.Providers -> {
                                navController.popBackStack()
                            }
                            ManualModelEntryContext.ProviderDetail -> {
                                navController.popBackStack()
                            }
                            ManualModelEntryContext.SkillEdit -> {
                                navController.popBackStack()
                                navController.popBackStack()
                            }
                        }
                    },
                )
            }
            composable<AppRoute.RelaySetup> { backStackEntry ->
                val route = backStackEntry.toRoute<AppRoute.RelaySetup>()
                LaunchedEffect(Unit) { PageTrace.end("RelaySetup") }
                RelaySetupScreen(
                    entryPoint = route.entryPoint,
                    onBack = { navController.popBackStack() },
                    onCompleted = { completion ->
                        when (completion) {
                            is RelaySetupCompletionTarget.ProviderDetail -> {
                                PageTrace.begin("ProviderDetail")
                                navController.navigate(
                                    AppRoute.ProviderDetail(completion.providerId, route.entryPoint),
                                ) {
                                    popUpTo(AppRoute.RelaySetup(route.entryPoint)) { inclusive = true }
                                    launchSingleTop = true
                                }
                            }

                            is RelaySetupCompletionTarget.ManualModelEntry -> {
                                PageTrace.begin("ManualModelEntry")
                                navController.navigate(
                                    AppRoute.ManualModelEntry(
                                        providerID = completion.providerId,
                                        context = when (route.entryPoint) {
                                            ProviderSetupEntryPoint.Onboarding -> ManualModelEntryContext.Onboarding
                                            ProviderSetupEntryPoint.SkillEdit -> ManualModelEntryContext.SkillEdit
                                            ProviderSetupEntryPoint.Providers -> ManualModelEntryContext.Providers
                                        },
                                    ),
                                ) {
                                    popUpTo(AppRoute.RelaySetup(route.entryPoint)) { inclusive = true }
                                    launchSingleTop = true
                                }
                            }
                        }
                    },
                )
            }
            composable<AppRoute.LocalComputeSetup> { backStackEntry ->
                val route = backStackEntry.toRoute<AppRoute.LocalComputeSetup>()

                LaunchedEffect(Unit) { PageTrace.end("LocalComputeSetup") }
                RelaySetupScreen(
                    entryPoint = route.entryPoint,
                    initialMethod = CustomLLMConnectionMethod.Local,
                    onBack = { navController.popBackStack() },
                    onCompleted = { completion ->
                        when (completion) {
                            is RelaySetupCompletionTarget.ProviderDetail -> {
                                PageTrace.begin("ProviderDetail")
                                navController.navigate(AppRoute.ProviderDetail(completion.providerId, route.entryPoint)) {
                                    popUpTo(AppRoute.LocalComputeSetup(route.entryPoint)) { inclusive = true }
                                    launchSingleTop = true
                                }
                            }
                            is RelaySetupCompletionTarget.ManualModelEntry -> Unit
                        }
                    },
                )
            }
            composable<AppRoute.Memory> {
                LaunchedEffect(Unit) { PageTrace.end("Memory") }
                MemoryScreen(
                    onNavigateBack = { navController.popBackStack() },
                )
            }
            composable<AppRoute.Backup> {
                LaunchedEffect(Unit) { PageTrace.end("Backup") }
                BackupScreen(
                    onBack = { navController.popBackStack() },
                )
            }
            composable<AppRoute.Skills> {
                LaunchedEffect(Unit) { PageTrace.end("Skills") }
                SkillsListScreen(
                    onBack = { navController.popBackStack() },
                    onNavigateToChat = { conversationId ->
                        PageTrace.begin("Chat")
                        navController.navigate(AppRoute.Chat(conversationId = conversationId))
                    },
                    onNavigateToEdit = { skillId ->
                        PageTrace.begin("SkillEdit")
                        navController.navigate(AppRoute.SkillEdit(skillId = skillId))
                    },
                    onNavigateToProviderSetup = {
                        PageTrace.begin("ProviderSetup")
                        navController.navigate(AppRoute.ProviderSetup(ProviderSetupEntryPoint.Providers))
                    },
                )
            }
            composable<AppRoute.SkillEdit> { backStackEntry ->
                val route = backStackEntry.toRoute<AppRoute.SkillEdit>()
                LaunchedEffect(Unit) { PageTrace.end("SkillEdit") }
                SkillEditScreen(
                    skillId = route.skillId,
                    onBack = { navController.popBackStack() },
                    onOpenOpenAISetup = {
                        PageTrace.begin("ProviderSetup")
                        navController.navigate(
                            AppRoute.ProviderSetup(
                                entryPoint = ProviderSetupEntryPoint.SkillEdit,
                                preselectedKind = ai.oriveo.community.core.model.ProviderKind.OpenAI,
                            ),
                        )
                    },
                    onOpenOpenAIProviderDetail = { providerID ->
                        PageTrace.begin("ProviderDetail")
                        navController.navigate(
                            AppRoute.ProviderDetail(
                                providerID = providerID,
                                entryPoint = ProviderSetupEntryPoint.SkillEdit,
                            ),
                        )
                    },
                )
            }
                }
            }
            } // CompositionLocalProvider(LocalRootTabTopInset)
            } // content layer
            } // hazeSource backdrop layer: the tab bar and the toast stay outside it, or the bar would
              // become part of its own source and sample nothing

            AnimatedVisibility(
                visible = shouldShowBottomBar,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    // The content layer no longer consumes systemBars as a whole: the bar sits
                    // max(21, navigation bar + 8) above the screen bottom, and the keyboard covers it when shown.
                    .padding(bottom = liquidGlassTabBarBottomGap()),
                enter = fadeIn(animationSpec = tween(220)) + slideInVertically(initialOffsetY = { it / 2 }),
                exit = fadeOut(animationSpec = tween(180)) + slideOutVertically(targetOffsetY = { it / 2 }),
            ) {
                // stringResource must be read in a composable scope; resolve the labels first so the items
                // are reused while language and theme stay the same.
                val tabBarLabels = tabs.map { stringResource(it.labelRes) }
                val isDarkTheme = OriveoTheme.isDark
                val tabBarItems = remember(tabBarLabels, isDarkTheme) {
                    tabs.mapIndexed { index, tab ->
                        LiquidGlassTabBarItem(
                            label = tabBarLabels[index],
                            glyph = tab.glyph,
                            selectedLabelColor = tabSelectedLabelColor(tab.route, isDarkTheme),
                        )
                    }
                }
                LiquidGlassTabBar(
                    items = tabBarItems,
                    selectedIndex = lastTabIndex,
                    hazeState = tabBarHazeState,
                    onSelect = { index ->
                        val tab = tabs[index]
                        val destination = navController.currentDestination
                        // Ignore taps while fading out (already on a full-screen page); re-tapping the current
                        // tab does not start a new page trace.
                        if (destination == null || destination.tabIndex() < 0) return@LiquidGlassTabBar
                        if (destination.hasRoute(tab.route::class)) return@LiquidGlassTabBar
                        PageTrace.begin(traceNameForTab(tab.route))
                        navController.navigate(tab.route) {
                            popUpTo(navController.graph.findStartDestination().id) {
                                saveState = true
                            }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                )
            }

            GlobalToastHost(
                messages = appViewModel.globalMessages,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding(),
            )

        }
    }
}
private fun currentRouteLabel(destination: androidx.navigation.NavDestination?): String = when {
    destination?.hasRoute(AppRoute.Home::class) == true -> "home"
    destination?.hasRoute(AppRoute.Providers::class) == true -> "providers"
    destination?.hasRoute(AppRoute.Settings::class) == true -> "settings"
    destination?.hasRoute(AppRoute.Chat::class) == true -> "chat"
    destination?.hasRoute(AppRoute.FolderDetail::class) == true -> "folder_detail"
    destination?.hasRoute(AppRoute.Notes::class) == true -> "notes"
    destination?.hasRoute(AppRoute.NoteDetail::class) == true -> "note_detail"
    destination?.hasRoute(AppRoute.Onboarding::class) == true -> "onboarding"
    destination?.hasRoute(AppRoute.ProviderSetup::class) == true -> "provider_setup"
    destination?.hasRoute(AppRoute.ProviderDetail::class) == true -> "provider_detail"
    destination?.hasRoute(AppRoute.ManualModelEntry::class) == true -> "manual_model_entry"
    destination?.hasRoute(AppRoute.RelaySetup::class) == true -> "relay_setup"
    destination?.hasRoute(AppRoute.Memory::class) == true -> "memory"
    destination?.hasRoute(AppRoute.Backup::class) == true -> "backup"
    destination?.hasRoute(AppRoute.Skills::class) == true -> "skills"
    destination?.hasRoute(AppRoute.SkillEdit::class) == true -> "skill_edit"
    else -> "unknown"
}
