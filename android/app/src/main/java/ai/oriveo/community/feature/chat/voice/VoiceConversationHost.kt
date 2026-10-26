package ai.oriveo.community.feature.chat.voice

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.view.accessibility.AccessibilityManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarMessage
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.data.database.LOCAL_PARTITION_ID
import ai.oriveo.community.core.context.ChatContextRequest
import ai.oriveo.community.core.memory.MemoryItemRepository
import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.voice.AndroidMicrophonePermission
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import ai.oriveo.community.core.voice.conversation.VoiceConversationServiceStarter
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.component.rememberGlobalSnackbarManager
import ai.oriveo.community.ui.util.findActivity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.koin.mp.KoinPlatform

/**
 * What a page needs to show the voice bar: the status to show (null = normal input area) and the bar actions.
 * Reading [status] only recomposes on status changes, never per audio level.
 */
@Stable
class VoiceConversationHandle internal constructor(
    val page: VoiceConversationPage,
    statusState: State<ConversationStatusKey?>,
    val level: StateFlow<Float>?,
    val onEnd: () -> Unit,
    val onTapOrb: () -> Unit,
    val onToggleMute: () -> Unit,
) {
    val status: ConversationStatusKey? by statusState
}

/** Where the page's turns go: the chat page's own port, or the home handoff. */
sealed interface VoiceConversationTarget {
    /**
     * Chat page: [port] builds the page's [ViewModelVoiceChatPort]; [context] is the chat send's context request
     * (ChatSendCoordinator.realtimeSessionContext with the page's memory items: no per-turn knowledge retrieval) a
     * realtime plan is built from.
     * With no [conversationId] yet (draft), a realtime plan uses [newConversation] and its first persist calls the
     * page's own [createConversation].
     */
    class Chat(
        val conversationId: String?,
        val context: suspend (Conversation) -> ChatContextRequest,
        val createConversation: (suspend () -> String?)? = null,
        val newConversation: (suspend () -> Conversation?)? = null,
        val port: () -> VoiceConversationChatPort,
    ) : VoiceConversationTarget

    /**
     * Home: the first transcript creates the conversation and navigates to it. [newConversation] = the conversation
     * the first send would create (home model, pending instructions) a realtime plan is built from. [returnHome]
     * (main thread, the conversation id) leaves the empty conversation a realtime session created, right before that
     * conversation is deleted (so no send can race the delete), only while it is still on screen
     *.
     */
    class Home(
        val createConversation: suspend () -> String?,
        val navigate: (String) -> Unit,
        val newConversation: (suspend () -> Conversation?)? = null,
        val returnHome: (String) -> Unit = {},
    ) : VoiceConversationTarget
}

/**
 * Voice conversation host of one page. Subscribes to the page's ≋ requests, runs the entry flow
 * ([VoiceConversationEntryFlow]: send gates → RECORD_AUDIO → one-time POST_NOTIFICATIONS → foreground service →
 * controller), surfaces controller events, announces the status word and ends the conversation when the
 * page goes away (✕ = user; leaving / switching conversations = system, except the home → chat handoff).
 * Without Koin (previews, UI tests) it does nothing and returns a handle with no status.
 */
@Composable
fun rememberVoiceConversationHost(
    page: VoiceConversationPage,
    requests: Flow<Unit>,
    target: VoiceConversationTarget,
    gate: suspend () -> Boolean,
    onDraftTranscript: (String) -> Unit,
): VoiceConversationHandle {
    val demo = VoiceConversationDemo.status
    if (demo != null) return rememberDemoHandle(page, demo)
    val cascade = remember { KoinPlatform.getKoinOrNull()?.getOrNull<VoiceConversationController>() }
    val realtimeBuilder = remember { KoinPlatform.getKoinOrNull()?.getOrNull<RealtimeVoiceSessionBuilder>() }
    // The realtime session of the last entry; null = the cascade drives the bar.
    var realtime by remember { mutableStateOf<RealtimeVoiceConversationEngine?>(null) }
    val controller = selectVoiceConversationEngine(cascade = cascade, realtime = realtime)
    val sessions = remember { KoinPlatform.getKoinOrNull()?.getOrNull<VoiceConversationSessions>() }
    if (controller == null || sessions == null) return rememberDemoHandle(page, null)
    val currentController by rememberUpdatedState(controller)

    val token = remember { Any() }
    val context = LocalContext.current
    val view = LocalView.current
    val scope = rememberCoroutineScope()
    val snackbar = rememberGlobalSnackbarManager()
    val currentTarget by rememberUpdatedState(target)
    val currentGate by rememberUpdatedState(gate)
    val currentDraft by rememberUpdatedState(onDraftTranscript)

    fun toast(res: Int, args: List<Any> = emptyList()) {
        snackbar?.show(GlobalSnackbarMessage(UiText.Resource(res, args), style = GlobalToastStyle.Error))
    }

    val notificationAsk = rememberNotificationPermissionAsk(context)
    val owned = remember { mutableStateOf(sessions.ownedBy(token)) }
    val active by controller.active.collectAsStateWithLifecycle()
    val rawStatus by controller.statusKey.collectAsStateWithLifecycle()
    val statusState = remember {
        derivedStateOf { if (active && sessions.ownedBy(token) && owned.value) rawStatus else null }
    }

    val announcer = remember {
        StatusAnnouncer(
            scope = scope,
            screenReaderOn = { isScreenReaderOn(context) },
            speak = { text -> @Suppress("DEPRECATION") view.announceForAccessibility(text) },
            onSpeaking = { speaking -> currentController.screenReaderSpeaking(speaking) },
        )
    }
    AnnounceVoiceStatus(statusState.value, announcer)

    // Home: the handoff port of the running conversation; released when it ends (see LaunchedEffect(active)).
    val homePortHolder = remember { arrayOfNulls<VoiceConversationSessions.HandoffPort>(1) }

    LaunchedEffect(requests) {
        var entering = false
        requests.collect {
            if (entering || currentController.active.value) return@collect
            entering = true
            launch {
                // Chosen once the microphone is granted: realtime runs without the foreground service.
                var chosen: RealtimeVoiceConversationEngine? = null
                // Home realtime: the handoff port whose first persist creates the conversation.
                var homePort: VoiceConversationSessions.HandoffPort? = null
                try {
                    VoiceConversationEntryFlow(
                        gate = { currentGate() },
                        microphone = {
                            val granted =
                                KoinPlatform.getKoinOrNull()?.getOrNull<AndroidMicrophonePermission>()?.request() ?: false
                            if (granted) {
                                val choice = realtimeBuilder?.let { builder ->
                                    prepareRealtimeVoiceSession(builder, currentTarget, ::homeContextRequest) {
                                        homePort?.conversationId()
                                    }
                                }
                                when (choice) {
                                    is RealtimeVoiceSessionChoice.Realtime -> chosen = choice.engine
                                    is RealtimeVoiceSessionChoice.Cascade -> choice.toast?.let { toast(it) }
                                    null -> Unit
                                }
                            }
                            granted
                        },
                        notifications = { notificationAsk() },
                        startService = {
                            val activity = context.findActivity()
                            when {
                                activity == null -> VoiceConversationServiceStarter.Result.NotVisible
                                chosen != null -> VoiceConversationServiceStarter.Result.Started
                                else -> VoiceConversationServiceStarter.start(activity)
                            }
                        },
                        startConversation = {
                            realtime = chosen
                            val engine = selectVoiceConversationEngine(cascade = cascade, realtime = chosen) ?: controller
                            when (val t = currentTarget) {
                                is VoiceConversationTarget.Chat -> {
                                    sessions.beginChat(token)
                                    owned.value = true
                                    engine.start(t.port())
                                }
                                is VoiceConversationTarget.Home -> {
                                    val port = sessions.beginHome(token, t.createConversation, t.navigate)
                                    homePort = port
                                    homePortHolder[0] = port
                                    owned.value = true
                                    engine.start(port)
                                }
                            }
                        },
                        onMicrophoneDenied = { toast(R.string.voice_dictation_mic_denied_title) },
                        onStartFailed = { toast(R.string.voice_conversation_start_failed_toast) },
                    ).run()
                } finally {
                    // Prepared but never started (a later entry step failed): release its sink.
                    chosen?.discard()
                    entering = false
                }
            }
        }
    }

    // Home → chat handoff: the chat page of the new conversation takes the running conversation over.
    val chatId = (target as? VoiceConversationTarget.Chat)?.conversationId
    val previousChatId = remember { arrayOfNulls<String>(1) }
    LaunchedEffect(chatId) {
        val t = currentTarget as? VoiceConversationTarget.Chat ?: return@LaunchedEffect
        if (sessions.attach(chatId, token, t.port)) {
            // A home realtime session keeps its engine: this page drives the same instance.
            realtimeBuilder?.running?.let { realtime = it }
            owned.value = true
        }
        val previous = previousChatId[0]
        previousChatId[0] = chatId
        // Switching to another conversation ends it; a draft becoming a real conversation does not.
        if (previous != null && previous != chatId && sessions.ownedBy(token) && currentController.active.value) {
            currentController.endLeavingPage()
        }
    }

    // Realtime has no foreground service: going to the background closes the session.
    DisposableEffect(Unit) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP) realtime?.systemInterruption()
        }
        val lifecycle = ProcessLifecycleOwner.get().lifecycle
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(controller) {
        controller.events.collect { event ->
            if (!sessions.ownedBy(token)) return@collect
            when (event) {
                is VoiceConversationEvent.StartFailed -> toast(R.string.voice_conversation_start_failed_toast)
                is VoiceConversationEvent.EngineFallback -> event.providerDisplayName?.let {
                    toast(R.string.voice_read_aloud_cloud_fallback, listOf(it))
                } ?: toast(R.string.voice_read_aloud_engine_fallback)
                is VoiceConversationEvent.TtsSelectionFallback -> toast(R.string.voice_read_aloud_engine_fallback)
                VoiceConversationEvent.PausedInBackground -> toast(R.string.voice_conversation_background_paused_toast)
                is VoiceConversationEvent.DraftTranscript -> currentDraft(event.text)
                is VoiceConversationEvent.Ended -> realtimeEndedToast(controller, event)?.let { toast(it) }
            }
        }
    }
    LaunchedEffect(active) {
        if (!active) {
            // A home conversation that ended before its first send gives up ownership (zero-round release).
            // Not once a chat page took it over: cancelling that would stop the chat page's generation.
            homePortHolder[0]?.takeIf { it.target.value == null }?.cancel()
            homePortHolder[0] = null
        }
        if (!active && sessions.ownedBy(token) && !sessions.handingOff) {
            // Ended (any reason): DraftTranscript may still arrive; ownership is dropped at the next start.
            announcer.reset()
        }
        owned.value = sessions.ownedBy(token)
    }

    DisposableEffect(Unit) {
        onDispose {
            val engine = currentController
            if (sessions.ownedBy(token) && !sessions.handingOff && engine.active.value) {
                engine.endLeavingPage()
            }
            announcer.reset()
        }
    }

    return remember(controller) {
        VoiceConversationHandle(
            page = page,
            statusState = statusState,
            level = controller.level,
            onEnd = { controller.end(EndReason.USER) },
            onTapOrb = controller::tapOrb,
            onToggleMute = controller::toggleMute,
        )
    }
}

/**
 * Prepares the realtime session for [target]. A chat draft (no conversation id) without a [VoiceConversationTarget.Chat.createConversation]
 * has nowhere to store the realtime turns, so it keeps the cascade. A chat draft creates its row through its own
 * page; home through the handoff ([homeConversationId]).
 */
internal suspend fun prepareRealtimeVoiceSession(
    builder: RealtimeVoiceSessionBuilder,
    target: VoiceConversationTarget,
    homeContext: suspend (Conversation) -> ChatContextRequest,
    homeConversationId: suspend () -> String?,
): RealtimeVoiceSessionChoice = when (target) {
    is VoiceConversationTarget.Chat -> {
        val create = target.createConversation
        if (target.conversationId == null && create == null) {
            RealtimeVoiceSessionChoice.Cascade()
        } else {
            // A chat page entry never creates on the first turn event and never deletes.
            builder.prepare(
                target.conversationId,
                target.context,
                target.newConversation,
                RealtimeConversationCreator(home = false, create = { create?.invoke() }),
            )
        }
    }
    is VoiceConversationTarget.Home -> builder.prepare(
        null,
        homeContext,
        target.newConversation,
        RealtimeConversationCreator(
            home = true,
            create = homeConversationId,
            onEmptyDeleted = { id -> withContext(Dispatchers.Main.immediate) { target.returnHome(id) } },
        ),
    )
}

/** Home realtime context: the new conversation's request with the local memory items. */
private suspend fun homeContextRequest(conversation: Conversation): ChatContextRequest {
    val items = KoinPlatform.getKoinOrNull()?.getOrNull<MemoryItemRepository>()?.observe(LOCAL_PARTITION_ID)?.first().orEmpty()
    return newConversationContextRequest(conversation, items)
}

/** Screen reader check used by the status announcer: touch exploration on (TalkBack and similar). */
internal fun isScreenReaderOn(context: Context): Boolean =
    (context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager)?.isTouchExplorationEnabled == true

/**
 * Which engine the voice bar drives: the realtime session chosen at entry when there is one, otherwise the
 * cascade [VoiceConversationController].
 */
internal fun selectVoiceConversationEngine(
    cascade: VoiceConversationEngine?,
    realtime: VoiceConversationEngine? = null,
): VoiceConversationEngine? = realtime ?: cascade

/**
 * Toast for a realtime session that ended with an error (Ended is emitted once per session). The cascade shows its
 * errors in the failed message card, so it gets none.
 */
internal fun realtimeEndedToast(engine: VoiceConversationEngine, event: VoiceConversationEvent.Ended): Int? =
    if (engine is RealtimeVoiceConversationEngine && event.reason == EndReason.ERROR) {
        R.string.voice_conversation_status_error
    } else {
        null
    }

@Composable
private fun rememberDemoHandle(page: VoiceConversationPage, status: ConversationStatusKey?): VoiceConversationHandle =
    remember(page, status) {
        VoiceConversationHandle(
            page = page,
            statusState = mutableStateOf(status),
            level = if (status == null) null else MutableStateFlow(0.35f),
            onEnd = {},
            onTapOrb = {},
            onToggleMute = {},
        )
    }

/**
 * POST_NOTIFICATIONS is asked once, on the first voice conversation, when not granted (API 33+). A denial
 * is final and never blocks (the service runs; the conversation ends in-app only).
 */
@Composable
private fun rememberNotificationPermissionAsk(context: Context): suspend () -> Unit {
    val pending = remember { arrayOfNulls<CompletableDeferred<Unit>>(1) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        pending[0]?.complete(Unit)
        pending[0] = null
    }
    val currentLauncher by rememberUpdatedState(launcher)
    return remember(context) {
        ask@{
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return@ask
            val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            if (granted) return@ask
            // The first prefs read loads the file from disk: keep it off the main thread.
            val firstAsk = withContext(Dispatchers.IO) {
                val prefs = context.applicationContext.getSharedPreferences(NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                val asked = prefs.getBoolean(KEY_NOTIFICATION_ASKED, false)
                if (!asked) prefs.edit().putBoolean(KEY_NOTIFICATION_ASKED, true).apply()
                !asked
            }
            if (!firstAsk) return@ask
            val result = CompletableDeferred<Unit>()
            pending[0]?.complete(Unit)
            pending[0] = result
            val launched = runCatching { currentLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) }.isSuccess
            if (launched) result.await()
        }
    }
}

private const val NOTIFICATION_PREFS = "voice_conversation"
private const val KEY_NOTIFICATION_ASKED = "notificationPermissionAsked"
