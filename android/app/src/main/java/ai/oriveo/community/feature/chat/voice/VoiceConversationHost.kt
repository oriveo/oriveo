package ai.oriveo.community.feature.chat.voice

import ai.oriveo.community.core.app.AppPreferencesRepository
import android.Manifest
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.voice.VoiceDirection
import ai.oriveo.community.core.voice.VoiceCatalog
import ai.oriveo.community.core.voice.VoiceEngineSelection
import ai.oriveo.community.core.voice.VoiceEngineSettings
import ai.oriveo.community.core.voice.realtime.RealtimeDrafts
import ai.oriveo.community.core.voice.realtime.RealtimeModel
import ai.oriveo.community.core.voice.realtime.RealtimeVoiceLog
import ai.oriveo.community.core.model.Provider
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.res.stringResource
import ai.oriveo.community.feature.settings.VoiceDisclosureSheet
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.view.HapticFeedbackConstants
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
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.content.ContextCompat
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
import ai.oriveo.community.core.voice.conversation.ConversationDisplayState
import ai.oriveo.community.core.voice.conversation.ConversationStatusKey
import ai.oriveo.community.core.voice.conversation.EndReason
import ai.oriveo.community.core.voice.conversation.VoiceConversationChatPort
import ai.oriveo.community.core.voice.conversation.VoiceConversationController
import ai.oriveo.community.core.voice.conversation.VoiceConversationEngine
import ai.oriveo.community.core.voice.conversation.VoiceConversationEvent
import ai.oriveo.community.core.voice.conversation.VoiceConversationService
import ai.oriveo.community.core.voice.conversation.VoiceConversationServiceStarter
import ai.oriveo.community.ui.component.isReduceMotionEnabled
import ai.oriveo.community.ui.component.rememberGlobalSnackbarManager
import ai.oriveo.community.ui.util.findActivity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.merge
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
    captionState: State<String>,
    nudgesState: State<Int>,
    private val languagePickerState: MutableState<Boolean> = mutableStateOf(false),
    private val capturePause: VoiceCapturePause = VoiceCapturePause {},
    private val onLanguageChanged: () -> Unit = {},
    userSpeakingState: State<Boolean> = mutableStateOf(false),
    failureState: State<RealtimeFailure?> = mutableStateOf(null),
    private val failureActions: RealtimeFailureActions = RealtimeFailureActions(),
    /** Realtime session: the bar shows a non-blank [caption] under any status, not only caption. */
    val realtimeCaption: Boolean = false,
    /** Realtime session: the chat list's live bubbles of the turn in progress; null = not a realtime session. */
    val drafts: StateFlow<RealtimeDrafts>? = null,
    /** Realtime session: who its stored turns are attributed to (the live bubbles' header); null = none. */
    val realtimeAttribution: RealtimeMessageAttribution? = null,
    /** Realtime session: ids of the messages it stored (the live bubbles' handover); null = none. */
    val realtimeCallMessageIds: StateFlow<Set<String>>? = null,
    switchingToState: State<String?> = mutableStateOf(null),
    /** The stage composed the switch notice of this model (see [VoiceSwitchingTo.shown]). */
    private val onSwitchNoticeShown: (String) -> Unit = {},
    typedSessionState: State<Boolean> = mutableStateOf(false),
) {
    /** A realtime session opened by typing runs (playback only): back-to-stage resumes capture on it. */
    val typedSessionRunning: Boolean by typedSessionState

    val status: ConversationStatusKey? by statusState

    /**
     * The display name of the model the running conversation is switching to (the old one ended, the entry
     * flow is opening the new one); null = not switching.
     */
    val switchingTo: String? by switchingToState

    /** The realtime failure the stage shows (orb at rest, card or max_duration word); null = none. */
    internal val failure: RealtimeFailure? by failureState

    /** The orb was tapped: after max_duration it starts a new call with the history, otherwise [onTapOrb]. */
    fun tapOrb() {
        if (realtimeFailureContinuesOnTap(failure)) failureActions.continueWithHistory() else onTapOrb()
    }

    /** A failure card button was tapped. */
    internal fun perform(action: RealtimeFailureAction) {
        val shown = failure ?: return
        when (action) {
            RealtimeFailureAction.OpenConnection -> failureActions.openConnection(shown.providerId)
            RealtimeFailureAction.Retry -> failureActions.retry()
            RealtimeFailureAction.SwitchModel -> failureActions.switchModel(realtimeFailureRestoresTextModel(shown))
            RealtimeFailureAction.ContinueWithHistory -> failureActions.continueWithHistory()
        }
    }

    /** The user is speaking (cascade only): the orb follows the voice before any caption shows. */
    val userSpeaking: Boolean by userSpeakingState

    /** The recognition language sheet is open over the conversation; capture is paused meanwhile. */
    val languagePickerOpen: Boolean by languagePickerState

    /** Opens the recognition language sheet: capture pauses until [closeLanguagePicker]. */
    fun openLanguagePicker() {
        if (languagePickerState.value) return
        languagePickerState.value = true
        capturePause.picker(true)
    }

    /** Closes the sheet ([changed] = a new language was saved: the next sentence uses it) and resumes capture. */
    fun closeLanguagePicker(changed: Boolean) {
        if (!languagePickerState.value) return
        languagePickerState.value = false
        if (changed) onLanguageChanged()
        capturePause.picker(false)
    }

    /** Live caption the bar shows in the status word's place: the cascade's transcript or the realtime engine's. */
    val caption: String by captionState

    /** How many times the reducer asked the orb for a light nudge; the motion itself belongs to the visual pass. */
    val nudges: Int by nudgesState

    /** The stage composed [switchingTo] = [model] once: the host may clear it now. */
    fun switchNoticeShown(model: String) = onSwitchNoticeShown(model)
}

/**
 * The model a running conversation is switching to. The old engine's end and the new entry flow can both
 * finish before the next frame, so the name is kept until the stage has composed it once ([shown]); otherwise the
 * "Switched to <model>" notice would never be seen.
 */
internal class VoiceSwitchingTo {
    private val name = mutableStateOf<String?>(null)
    private var shownOnce = false
    private var finished = false

    val state: State<String?> get() = name

    /** A switch to [model] starts (null = no notice). */
    fun begin(model: String?) {
        shownOnce = false
        finished = false
        name.value = model
        VoiceSwitchNoticeLatch.record(model)
    }

    /** The entry flow the switch started is over (or was ignored): clear now, or once the stage has shown it. */
    fun done() {
        if (name.value == null || shownOnce) name.value = null else finished = true
    }

    /** The stage composed the notice of [model]. */
    fun shown(model: String) {
        if (model != name.value) return
        shownOnce = true
        if (finished) name.value = null
    }
}

/**
 * Ways out of a realtime failure: [retry] and [continueWithHistory] enter again (a new session planned from
 * the conversation's history), [openConnection] opens the connection details, [switchModel] the model picker.
 */
internal class RealtimeFailureActions(
    val retry: () -> Unit = {},
    val openConnection: (String) -> Unit = {},
    /** true = return to the last text model first (model_gone), then open the picker. */
    val switchModel: (Boolean) -> Unit = {},
    val continueWithHistory: () -> Unit = {},
)

/**
 * Capture is paused while the screen reader speaks the status word or the recognition language sheet is open;
 * [apply] gets the merged state, only when it changes, so closing one never resumes capture the other still holds.
 */
internal class VoiceCapturePause(private val apply: (Boolean) -> Unit) {
    private var screenReader = false
    private var picker = false
    private var paused = false

    fun screenReader(speaking: Boolean) {
        screenReader = speaking
        sync()
    }

    fun picker(open: Boolean) {
        picker = open
        sync()
    }

    private fun sync() {
        val want = screenReader || picker
        if (want == paused) return
        paused = want
        apply(want)
    }
}

/** Where the page's turns go: the chat page's own port, or the home handoff. */
sealed interface VoiceConversationTarget {
    /**
     * Chat page: [port] builds the page's [ViewModelVoiceChatPort]; [context] is the chat send's context request
     * (ChatSendCoordinator.realtimeSessionContext with the page's memory items: no per-turn knowledge retrieval) a
     * realtime plan is built from.
     * With no [conversationId] yet (draft), a realtime plan uses [newConversation] and its first persist calls the
     * page's own [createConversation]. [onOpenConnection] (connection id) / [onSwitchModel] are the realtime failure
     * card's ways out: the page's connection details and model picker. [realtimeSelection] / [onSelectRealtime] as
     * on [VoiceConversationTarget].
     */
    class Chat(
        val conversationId: String?,
        val context: suspend (Conversation) -> ChatContextRequest,
        val createConversation: (suspend () -> String?)? = null,
        val newConversation: (suspend () -> Conversation?)? = null,
        override val onOpenConnection: (String) -> Unit = {},
        override val onSwitchModel: (Boolean) -> Unit = {},
        override val realtimeSelection: VoiceEngineSelection.Cloud? = null,
        override val onSelectRealtime: (VoiceEngineSelection.Cloud) -> Unit = {},
        override val modelName: String? = null,
        val port: () -> VoiceConversationChatPort,
    ) : VoiceConversationTarget

    /**
     * Home: the first transcript creates the conversation and navigates to it. [newConversation] = the conversation
     * the first send would create (home model, pending instructions) a realtime plan is built from. [returnHome]
     * (main thread, the conversation id) leaves the empty conversation a realtime session created, right before that
     * conversation is deleted (so no send can race the delete), only while it is still on screen
     * (realtime-conversation rules.host). [onOpenConnection] / [onSwitchModel] / [realtimeSelection] /
     * [onSelectRealtime] as for [Chat]; the home pill's realtime model is the selection.
     */
    class Home(
        val createConversation: suspend () -> String?,
        val navigate: (String) -> Unit,
        val newConversation: (suspend () -> Conversation?)? = null,
        val returnHome: (String) -> Unit = {},
        override val onOpenConnection: (String) -> Unit = {},
        override val onSwitchModel: (Boolean) -> Unit = {},
        override val realtimeSelection: VoiceEngineSelection.Cloud? = null,
        override val onSelectRealtime: (VoiceEngineSelection.Cloud) -> Unit = {},
        override val modelName: String? = null,
    ) : VoiceConversationTarget

    /** Realtime failure card: open the details of the connection (id) the session ran on. */
    val onOpenConnection: (String) -> Unit

    /**
     * Realtime failure card: open the page's model picker; true = first return the page's selection to the last used
     * text model when it is still usable (model_gone, design §6.6).
     */
    val onSwitchModel: (Boolean) -> Unit

    /**
     * The page's realtime model (its connection + model) when the chat / home pill selected one: entering (the voice
     * dock's orb) opens it, never the cascade; null = a text model, whose ≋ is always the cascade.
     */
    val realtimeSelection: VoiceEngineSelection.Cloud?

    /** Migration "Switch to <model>": select [VoiceEngineSelection.Cloud] as the page's model. */
    val onSelectRealtime: (VoiceEngineSelection.Cloud) -> Unit

    /** The display name of the page's selected model (the switch notice); null = fall back to the model id. */
    val modelName: String?
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
    /** A typed sentence sent to this page's realtime model: sent on the open realtime session; if there is none, opens a connection without the mic and sends it. */
    typed: Flow<String> = emptyFlow(),
    /**
     * Outcome of a typed sentence: (text, [RealtimeModel] TYPED_* outcome). Only persisted clears the input box; session open failure / declined disclosure /
     * ended before persisting / leaving the page are all reported back, and the original text stays in the input box.
     */
    onTypedOutcome: (String, String) -> Unit = { _, _ -> },
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
    val currentTypedOutcome by rememberUpdatedState(onTypedOutcome)

    fun toast(res: Int, args: List<Any> = emptyList()) {
        snackbar?.show(GlobalSnackbarMessage(UiText.Resource(res, args), style = GlobalToastStyle.Error))
    }

    val notificationAsk = rememberNotificationPermissionAsk(context)
    val owned = remember { mutableStateOf(sessions.ownedBy(token)) }
    val active by controller.active.collectAsStateWithLifecycle()
    val rawStatus by controller.statusKey.collectAsStateWithLifecycle()
    // Live caption: the cascade's transcript, or the realtime engine's (assistant reveal while speaking, else the user).
    val captionFlow = remember(controller) { voiceConversationCaption(controller) }
    val captionState = captionFlow.collectAsStateWithLifecycle()
    val nudges = remember { mutableIntStateOf(0) }
    // Only the cascade reports speech before a caption; realtime keeps the listening orb.
    val displayFlow = remember(controller) {
        (controller as? VoiceConversationController)?.displayState ?: MutableStateFlow<ConversationDisplayState?>(null)
    }
    val display by displayFlow.collectAsStateWithLifecycle()
    val userSpeakingState = remember(displayFlow) { derivedStateOf { display == ConversationDisplayState.USER_SPEAKING } }
    // A realtime session that failed keeps the stage with the orb at rest and its failure in the caption slot.
    val failureFlow = remember(controller) {
        (controller as? RealtimeVoiceConversationEngine)?.failure ?: MutableStateFlow<RealtimeFailure?>(null)
    }
    val rawFailure by failureFlow.collectAsStateWithLifecycle()
    // Realtime session opened by typing (playback only): the page stays in typing mode and does not enter the stage; status shows only after switching back to the voice stage opens capture.
    val capturingFlow = remember(controller) {
        (controller as? RealtimeVoiceConversationEngine)?.capturing ?: MutableStateFlow(true)
    }
    val capturing by capturingFlow.collectAsStateWithLifecycle()
    // The conversation's realtime model did not open (prepare failed): shown like a session failure, no engine yet.
    val preStartFailure = remember { mutableStateOf<RealtimeFailure?>(null) }
    // The realtime disclosure to show before entering (the conversation's realtime model, not accepted yet).
    val disclosureKind = remember { mutableStateOf<ProviderKind?>(null) }
    // Upgrade migration of the old engine setting: its prompt, then the disclosure a switch may need.
    val migration = remember { realtimeBuilder?.migration() }
    val migrationPrompt = remember { mutableStateOf<RealtimeVoiceMigration.Step.Prompt?>(null) }
    val migrationDisclosure = remember { mutableStateOf<RealtimeVoiceMigration.Step.Disclosure?>(null) }
    // A zero-turn home session ends with a failure and releases ownership: the failure card still stays on this page.
    val releasedOnFailure = remember { mutableStateOf(false) }
    val failureState = remember {
        derivedStateOf {
            stageFailure(
                failure = rawFailure ?: preStartFailure.value,
                owned = sessions.ownedBy(token) && owned.value,
                releasedOnFailure = releasedOnFailure.value,
                sessions = sessions,
            )?.takeIf { failureMatchesSelection(it, currentTarget.realtimeSelection) }
        }
    }
    val statusState = remember {
        derivedStateOf {
            // A failure does not take over the session stage (same as iOS): the failure card is shown in the idle stage (RealtimeVoiceDock) instead, see failureState.
            when {
                !sessions.ownedBy(token) || !owned.value -> null
                active && !capturing -> null
                active -> rawStatus
                else -> null
            }
        }
    }
    // A session opened by typing is running (going back to the voice stage decides whether to open capture or only show the idle stage).
    val typedSessionState = remember { derivedStateOf { active && !capturing } }
    // Retry / continue with history: the same entry flow as the page's ≋ (gates, plan from the history).
    val reentries = remember { MutableSharedFlow<Unit>(extraBufferCapacity = 1) }
    // The sentence to resend after consent, when a realtime disclosure must be accepted before opening a session by typing; null = the disclosure came from the ≋ entry.
    val pendingTyped = remember { PendingTypedSend { text, outcome -> currentTypedOutcome(text, outcome) } }
    val typedRetries = remember { MutableSharedFlow<String>(extraBufferCapacity = 1) }
    // The model a running conversation is switching to; cleared once the entry flow it started is done.
    val switchingTo = remember { VoiceSwitchingTo() }

    val capturePause = remember { VoiceCapturePause { paused -> currentController.screenReaderSpeaking(paused) } }
    val languagePicker = remember { mutableStateOf(false) }
    val announcer = remember {
        StatusAnnouncer(
            scope = scope,
            screenReaderOn = { isScreenReaderOn(context) },
            speak = { text -> @Suppress("DEPRECATION") view.announceForAccessibility(text) },
            onSpeaking = capturePause::screenReader,
        )
    }
    AnnounceVoiceStatus(statusState.value, announcer, failureState.value, switchingTo.state.value)

    // Home: the handoff port of the running conversation; released when it ends (see LaunchedEffect(active)).
    val homePortHolder = remember { arrayOfNulls<VoiceConversationSessions.HandoffPort>(1) }

    fun startService(
        kind: VoiceConversationService.Kind = VoiceConversationService.Kind.Microphone,
    ): VoiceConversationServiceStarter.Result {
        val activity = context.findActivity() ?: return VoiceConversationServiceStarter.Result.NotVisible
        return VoiceConversationServiceStarter.start(activity, kind)
    }

    LaunchedEffect(requests) {
        var entering = false
        merge(requests, reentries).collect {
            RealtimeVoiceLog.d(
                "host entry page=$page entering=$entering active=${currentController.active.value} " +
                    "realtime=${currentTarget.realtimeSelection != null}",
            )
            // Going back to the voice stage from a session opened by typing: open capture on the same connection (mic permission → the same foreground service switches to microphone), enter the stage, and do not reopen the connection.
            val typedSession = (currentController as? RealtimeVoiceConversationEngine)
                ?.takeIf { it.active.value && !it.capturing.value }
            if (!entering && typedSession != null) {
                entering = true
                launch {
                    try {
                        VoiceConversationEntryFlow(
                            gate = { currentGate() },
                            microphone = {
                                KoinPlatform.getKoinOrNull()?.getOrNull<AndroidMicrophonePermission>()?.request() ?: false
                            },
                            notifications = { notificationAsk() },
                            startService = { startService() },
                            startConversation = { resumeCaptureBackToStage(typedSession) },
                            onMicrophoneDenied = { toast(R.string.voice_dictation_mic_denied_title) },
                            // The service cannot switch to microphone: failure card in the stage, no toast.
                            onStartFailed = { typedSession.captureStartFailed() },
                        ).run()
                    } finally {
                        entering = false
                    }
                }
                RealtimeVoiceLog.d("host entry: capture on typed session")
                return@collect
            }
            if (entering || currentController.active.value) {
                RealtimeVoiceLog.d("host entry ignored: entering=$entering active=${currentController.active.value}")
                switchingTo.done()
                return@collect
            }
            entering = true
            launch {
                // Chosen once the microphone is granted; realtime runs under the same foreground service.
                var chosen: RealtimeVoiceConversationEngine? = null
                // prepare stopped the entry (a failure on the stage or the disclosure first): not a denied microphone.
                var halted = false
                preStartFailure.value = null
                // Home realtime: the handoff port whose first persist creates the conversation (contract item 7).
                var homePort: VoiceConversationSessions.HandoffPort? = null
                try {
                    // ≋ (no realtime model selected): the first tap after the upgrade may ask about the old setting.
                    if (currentTarget.realtimeSelection == null) {
                        val step = migration?.check()
                        if (step is RealtimeVoiceMigration.Step.Prompt) {
                            RealtimeVoiceLog.d("host entry: migration prompt")
                            migrationPrompt.value = step
                            return@launch
                        }
                    }
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
                                RealtimeVoiceLog.d("host entry prepared: ${choice?.let { it::class.simpleName }}")
                                when (choice) {
                                    is RealtimeVoiceSessionChoice.Realtime -> chosen = choice.engine
                                    is RealtimeVoiceSessionChoice.Failed -> {
                                        halted = true
                                        sessions.beginChat(token)
                                        owned.value = true
                                        preStartFailure.value = choice.failure
                                    }
                                    is RealtimeVoiceSessionChoice.Disclosure -> {
                                        halted = true
                                        disclosureKind.value = choice.providerKind
                                    }
                                    is RealtimeVoiceSessionChoice.Cascade, null -> Unit
                                }
                            }
                            granted && !halted
                        },
                        notifications = { notificationAsk() },
                        startService = { startService() },
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
                        onMicrophoneDenied = { if (!halted) toast(R.string.voice_dictation_mic_denied_title) },
                        // The realtime entry's foreground service cannot start: unknown failure card in the stage, no toast; the cascade still toasts as before.
                        onStartFailed = {
                            val engine = chosen
                            if (engine == null) {
                                toast(R.string.voice_conversation_start_failed_toast)
                            } else {
                                sessions.beginChat(token)
                                owned.value = true
                                preStartFailure.value = engine.unknownFailure()
                            }
                        },
                    ).run()
                } finally {
                    // Prepared but never started (a later entry step failed): release its sink.
                    chosen?.discard()
                    entering = false
                    switchingTo.done()
                }
            }
        }
    }

    // Typed-mode send: an open realtime session sends directly; if there is none, open a playback-only connection on this page's realtime model (no mic, foreground service starts with mediaPlayback), then send.
    LaunchedEffect(typed) {
        merge(typed, typedRetries).collect { text ->
            val builder = realtimeBuilder ?: return@collect currentTypedOutcome(text, RealtimeModel.TYPED_OPEN_FAILED)
            val running = (currentController as? RealtimeVoiceConversationEngine)?.takeIf { it.active.value }
            var homePort: VoiceConversationSessions.HandoffPort? = null
            preStartFailure.value = null
            val choice = sendRealtimeTyped(
                text = text,
                running = running,
                open = {
                    prepareRealtimeVoiceSession(builder, currentTarget, ::homeContextRequest, capture = false) {
                        homePort?.conversationId()
                    }
                },
                startService = { startService(VoiceConversationService.Kind.MediaPlayback) },
                onOutcome = { outcome -> currentTypedOutcome(text, outcome) },
            ) { engine ->
                realtime = engine
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
            }
            when (choice) {
                is RealtimeVoiceSessionChoice.Failed -> {
                    sessions.beginChat(token)
                    owned.value = true
                    preStartFailure.value = choice.failure
                }
                is RealtimeVoiceSessionChoice.Disclosure -> {
                    pendingTyped.hold(text)
                    disclosureKind.value = choice.providerKind
                }
                is RealtimeVoiceSessionChoice.Cascade, is RealtimeVoiceSessionChoice.Realtime, null -> Unit
            }
        }
    }

    // The page's model changed while its voice conversation runs and the answering engine differs → end it
    // (user end) and enter again with the new target. A realtime session opened by typing (no capture) only ends
    // The next typed sentence opens the new model.
    val engineKey = target.realtimeSelection.voiceEngineKey()
    val lastEngineKey = remember { arrayOf(engineKey) }
    LaunchedEffect(engineKey) {
        val previous = lastEngineKey[0]
        lastEngineKey[0] = engineKey
        val running = currentController
        if (!sessions.ownedBy(token)) {
            if (previous != engineKey) RealtimeVoiceLog.d("host engine key changed, not owner: realtime=${engineKey != null}")
            return@LaunchedEffect
        }
        val capturing = (running as? RealtimeVoiceConversationEngine)?.capturing?.value != false
        if (!shouldSwitchEngine(previous, engineKey, running.active.value)) {
            if (previous != engineKey) {
                RealtimeVoiceLog.d("host engine key changed, no switch: realtime=${engineKey != null} active=${running.active.value}")
            }
            return@LaunchedEffect
        }
        if (capturing) switchingTo.begin(voiceEngineSwitchName(currentTarget))
        RealtimeVoiceLog.d("host engine switch: realtime=${engineKey != null} capturing=$capturing")
        switchVoiceEngine(running, previous, engineKey, capturing) { reentries.tryEmit(Unit) }
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
        // A sentence waiting on the disclosure belongs to the conversation left behind: its text stays.
        if (previous != null && previous != chatId) pendingTyped.leave()
        // Switching to another conversation ends it; a draft becoming a real conversation does not.
        if (previous != null && previous != chatId && sessions.ownedBy(token) && currentController.active.value) {
            currentController.endLeavingPage()
        }
    }

    LaunchedEffect(controller) {
        controller.events.collect { event ->
            if (!sessions.ownedBy(token)) return@collect
            voiceConversationEventToast(event, realtime = controller is RealtimeVoiceConversationEngine)
                ?.let { (res, args) -> toast(res, args) }
            when (event) {
                is VoiceConversationEvent.StartFailed, is VoiceConversationEvent.EngineFallback,
                is VoiceConversationEvent.TtsSelectionFallback, VoiceConversationEvent.PausedInBackground,
                is VoiceConversationEvent.Ended,
                -> Unit
                is VoiceConversationEvent.DraftTranscript -> currentDraft(event.text)
                // Follows the system touch-feedback setting (no FLAG_IGNORE_GLOBAL_SETTING).
                is VoiceConversationEvent.Haptic -> view.performHapticFeedback(
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        HapticFeedbackConstants.CONFIRM
                    } else {
                        HapticFeedbackConstants.KEYBOARD_TAP
                    },
                )
                VoiceConversationEvent.NudgeOrb -> nudges.intValue++
            }
        }
    }
    LaunchedEffect(active) {
        if (!active) {
            // A home conversation that ended before its first send gives up ownership (zero-round release).
            // Not once a chat page took it over: cancelling that would stop the chat page's generation.
            releasedOnFailure.value = releaseHomeZeroTurn(homePortHolder[0], failureFlow.value)
            homePortHolder[0] = null
        } else {
            releasedOnFailure.value = false
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
            pendingTyped.leave()
            announcer.reset()
        }
    }

    disclosureKind.value?.let { kind ->
        VoiceDisclosureSheet(
            direction = VoiceDirection.Realtime,
            providerKind = kind,
            onAgree = {
                disclosureKind.value = null
                realtimeBuilder?.acceptDisclosure(kind)
                val retry = pendingTyped.take()
                if (retry != null) typedRetries.tryEmit(retry) else reentries.tryEmit(Unit)
            },
            // Declined: stays on the voice dock, nothing opens.
            onDecline = {
                disclosureKind.value = null
                pendingTyped.decline()
            },
        )
    }

    fun migrated(step: RealtimeVoiceMigration.Step) {
        when (step) {
            RealtimeVoiceMigration.Step.Cascade -> reentries.tryEmit(Unit)
            is RealtimeVoiceMigration.Step.SelectRealtime -> currentTarget.onSelectRealtime(step.selection)
            is RealtimeVoiceMigration.Step.Disclosure -> migrationDisclosure.value = step
            is RealtimeVoiceMigration.Step.Prompt, RealtimeVoiceMigration.Step.None -> Unit
        }
    }
    migrationPrompt.value?.let { prompt ->
        RealtimeMigrationPrompt(
            model = prompt.selection.model,
            onAnswer = { answer ->
                migrationPrompt.value = null
                migration?.let { m -> scope.launch { migrated(m.answer(answer)) } }
            },
        )
    }
    migrationDisclosure.value?.let { step ->
        VoiceDisclosureSheet(
            direction = VoiceDirection.Realtime,
            providerKind = step.selection.providerKind,
            onAgree = {
                migrationDisclosure.value = null
                migration?.let { migrated(it.disclosureAnswered(step, accepted = true)) }
            },
            onDecline = {
                migrationDisclosure.value = null
                migration?.let { migrated(it.disclosureAnswered(step, accepted = false)) }
            },
        )
    }

    val failureActions = remember {
        fun dismiss() {
            preStartFailure.value = null
            (currentController as? RealtimeVoiceConversationEngine)?.dismissFailure()
        }
        RealtimeFailureActions(
            retry = { reentries.tryEmit(Unit) },
            openConnection = { id ->
                dismiss()
                currentTarget.onOpenConnection(id)
            },
            switchModel = { restore ->
                dismiss()
                currentTarget.onSwitchModel(restore)
            },
            continueWithHistory = { reentries.tryEmit(Unit) },
        )
    }

    return remember(controller) {
        VoiceConversationHandle(
            page = page,
            statusState = statusState,
            level = controller.level,
            onEnd = {
                if (controller.active.value) {
                    controller.end(EndReason.USER)
                } else {
                    preStartFailure.value = null
                    (controller as? RealtimeVoiceConversationEngine)?.dismissFailure()
                }
            },
            onTapOrb = controller::tapOrb,
            onToggleMute = controller::toggleMute,
            captionState = captionState,
            nudgesState = nudges,
            languagePickerState = languagePicker,
            capturePause = capturePause,
            onLanguageChanged = controller::recognitionLanguageChanged,
            userSpeakingState = userSpeakingState,
            failureState = failureState,
            failureActions = failureActions,
            realtimeCaption = controller is RealtimeVoiceConversationEngine,
            drafts = (controller as? RealtimeVoiceConversationEngine)?.drafts,
            realtimeAttribution = (controller as? RealtimeVoiceConversationEngine)?.attribution,
            realtimeCallMessageIds = (controller as? RealtimeVoiceConversationEngine)?.callMessageIds,
            switchingToState = switchingTo.state,
            onSwitchNoticeShown = switchingTo::shown,
            typedSessionState = typedSessionState,
        )
    }
}

/** The caption flow the handle shows for [engine]: the cascade's or the realtime engine's live caption, else none. */
internal fun voiceConversationCaption(engine: VoiceConversationEngine): StateFlow<String> = when (engine) {
    is VoiceConversationController -> engine.caption
    is RealtimeVoiceConversationEngine -> engine.caption
    else -> MutableStateFlow("")
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
    /** false = a session opened by typing: playback only, no mic. */
    capture: Boolean = true,
    homeConversationId: suspend () -> String?,
): RealtimeVoiceSessionChoice = when (target) {
    is VoiceConversationTarget.Chat -> {
        val create = target.createConversation
        if (target.conversationId == null && create == null) {
            RealtimeVoiceSessionChoice.Cascade
        } else {
            // A chat page entry never creates on the first turn event and never deletes.
            builder.prepare(
                target.conversationId,
                target.context,
                target.newConversation,
                RealtimeConversationCreator(home = false, create = { create?.invoke() }),
                target.realtimeSelection,
                capture,
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
        target.realtimeSelection,
        capture,
    )
}

/**
 * Typed-mode sentence sent to the realtime model: [running] if open, it is sent on it (if the AI is speaking, first interrupt by the played ms); if none, [open]
 * a playback-only session, and [start] opens it before sending. Returns the [open] result (the host shows the failure / disclosure from it); null when reused.
 * Never goes through the text chat API.
 */
internal suspend fun sendRealtimeTyped(
    text: String,
    running: RealtimeVoiceConversationEngine?,
    open: suspend () -> RealtimeVoiceSessionChoice,
    /** Starts the foreground service as mediaPlayback before the session (a background / locked screen keeps it). */
    startService: () -> VoiceConversationServiceStarter.Result = { VoiceConversationServiceStarter.Result.Started },
    onOutcome: (String) -> Unit = {},
    start: (RealtimeVoiceConversationEngine) -> Unit,
): RealtimeVoiceSessionChoice? {
    if (running != null && running.active.value) {
        running.sendTyped(text, onOutcome)
        return null
    }
    when (val choice = open()) {
        is RealtimeVoiceSessionChoice.Realtime -> {
            when (startService()) {
                VoiceConversationServiceStarter.Result.Started -> Unit
                // Not visible any more: the user already left; nothing opens, nothing to say.
                VoiceConversationServiceStarter.Result.NotVisible -> {
                    choice.engine.discard()
                    onOutcome(RealtimeModel.TYPED_HOST_LEFT)
                    return null
                }
                // The service did not start: the in-stage unknown card, never a toast.
                else -> {
                    choice.engine.discard()
                    onOutcome(RealtimeModel.TYPED_OPEN_FAILED)
                    return RealtimeVoiceSessionChoice.Failed(choice.engine.unknownFailure())
                }
            }
            start(choice.engine)
            choice.engine.sendTyped(text, onOutcome)
            return choice
        }
        // Did not open (the in-stage card) or no realtime model to send to: the sentence goes nowhere.
        is RealtimeVoiceSessionChoice.Failed, is RealtimeVoiceSessionChoice.Cascade -> {
            onOutcome(RealtimeModel.TYPED_OPEN_FAILED)
            return choice
        }
        // The host holds the sentence until the disclosure is answered.
        is RealtimeVoiceSessionChoice.Disclosure -> return choice
    }
}

/**
 * Upgrade migration of the old realtime engine setting, asked on the first ≋ tap while the old keys
 * exist. [RealtimeModel.migration] decides every step; the old keys are deleted once it says so, consent records stay.
 */
internal class RealtimeVoiceMigration(
    private val settings: VoiceEngineSettings,
    private val catalog: suspend () -> VoiceCatalog?,
    private val providers: suspend () -> List<Provider>,
) {
    sealed interface Step {
        /** Enter the cascade conversation. */
        data object Cascade : Step

        /** Ask "Realtime voice has moved to the model picker" with [selection]'s model on the switch button. */
        data class Prompt(val selection: VoiceEngineSelection.Cloud) : Step

        /** Select [selection] as the page's model (its voice dock shows); nothing opens yet. */
        data class SelectRealtime(val selection: VoiceEngineSelection.Cloud) : Step

        /** Show [selection]'s realtime disclosure first; declining it continues with [declined]. */
        data class Disclosure(val selection: VoiceEngineSelection.Cloud, val declined: Step) : Step

        /** The prompt went away unanswered: nothing enters, the next ≋ tap asks again. */
        data object None : Step
    }

    /** On a ≋ tap: [Step.Prompt] when the old choice still resolves, otherwise [Step.Cascade]. */
    suspend fun check(): Step {
        val old = oldState() ?: return Step.Cascade
        // The voice catalog is unknown (not loaded / unreachable): nothing is judged unresolvable, the keys stay.
        if (old.catalog == null) return Step.Cascade
        val result = decide(old, answer = null)
        val selection = old.selection
        return if (result.showPrompt && selection != null) Step.Prompt(selection) else Step.Cascade
    }

    /** The prompt's [answer]: [RealtimeModel.ANSWER_SWITCH] / [RealtimeModel.ANSWER_KEEP] / [RealtimeModel.ANSWER_DISMISSED]. */
    suspend fun answer(answer: String): Step {
        val old = oldState() ?: return Step.Cascade
        if (old.catalog == null) return Step.Cascade
        val result = decide(old, answer)
        val selection = old.selection
        if (!result.showPrompt || selection == null) return Step.Cascade
        return when (result.result) {
            RealtimeModel.MIGRATION_SELECT_REALTIME -> if (result.showDisclosure) {
                Step.Disclosure(selection, step(RealtimeModel.migration(
                    oldKeyPresent = true,
                    oldChoice = old.choice,
                    realtimeCatalog = old.catalog.orEmpty(),
                    connections = old.connections,
                    consented = old.consented,
                    answer = answer,
                    disclosureDeclined = true,
                ).result, selection))
            } else {
                Step.SelectRealtime(selection)
            }
            else -> step(result.result, selection)
        }
    }

    /** The disclosure a switch asked for was answered; agreeing records the consent. */
    fun disclosureAnswered(disclosure: Step.Disclosure, accepted: Boolean): Step {
        if (!accepted) return disclosure.declined
        settings.disclosure.markAccepted(disclosure.selection.providerKind, VoiceDirection.Realtime)
        return Step.SelectRealtime(disclosure.selection)
    }

    private fun step(result: String, selection: VoiceEngineSelection.Cloud): Step = when (result) {
        RealtimeModel.MIGRATION_SELECT_REALTIME -> Step.SelectRealtime(selection)
        RealtimeModel.MIGRATION_ENTER_CASCADE -> Step.Cascade
        else -> Step.None
    }

    /** The old setting with what [RealtimeModel.migration] reads; null = no old keys. [catalog] null = unknown. */
    private class OldState(
        val selection: VoiceEngineSelection.Cloud?,
        val choice: RealtimeModel.OldChoice?,
        val catalog: Map<String, List<RealtimeModel.RealtimeCatalogEntry>>?,
        val connections: List<RealtimeModel.Connection>,
        val consented: Boolean,
    )

    private suspend fun oldState(): OldState? {
        // Off the main thread: the first read of the settings file may load it.
        val legacy = withContext(Dispatchers.IO) { settings.legacyRealtimeChoice() } ?: return null
        val selection = (legacy as? VoiceEngineSelection.Cloud)?.copy(voice = null)
        val realtime = catalog()?.providers?.map { (kind, entries) ->
            kind.rawValue to entries.realtime.map { RealtimeModel.RealtimeCatalogEntry(it.model, it.isDefault) }
        }?.toMap()
        return OldState(
            selection = selection,
            choice = selection?.let { RealtimeModel.OldChoice(it.providerKind.rawValue, it.model, it.connectionId) },
            catalog = realtime,
            connections = providers().map {
                RealtimeModel.Connection(it.id, it.kind.rawValue, RealtimeModel.connectionAuth(it.kind, it.authMode))
            },
            consented = selection?.let { settings.disclosure.isAccepted(it.providerKind, VoiceDirection.Realtime) } == true,
        )
    }

    private fun decide(old: OldState, answer: String?): RealtimeModel.MigrationResult {
        val result = RealtimeModel.migration(
            oldKeyPresent = true,
            oldChoice = old.choice,
            realtimeCatalog = old.catalog.orEmpty(),
            connections = old.connections,
            consented = old.consented,
            answer = answer,
        )
        if (result.deleteOldKeys) settings.clearLegacyRealtime()
        return result
    }
}

/**
 * "Realtime voice has moved to the model picker": switch to [model] or keep the current model; going away
 * without an answer (back, outside tap) is [RealtimeModel.ANSWER_DISMISSED].
 */
@Composable
private fun RealtimeMigrationPrompt(model: String, onAnswer: (String) -> Unit) {
    AlertDialog(
        onDismissRequest = { onAnswer(RealtimeModel.ANSWER_DISMISSED) },
        title = { Text(stringResource(R.string.voice_realtime_moved_title)) },
        confirmButton = {
            TextButton(
                onClick = { onAnswer(RealtimeModel.ANSWER_SWITCH) },
                modifier = Modifier,
            ) {
                Text(stringResource(R.string.voice_realtime_moved_switch, model))
            }
        },
        dismissButton = {
            TextButton(
                onClick = { onAnswer(RealtimeModel.ANSWER_KEEP) },
                modifier = Modifier,
            ) {
                Text(stringResource(R.string.voice_realtime_moved_keep))
            }
        },
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
 * Toast (string resource, format args) a conversation event shows; null = none. Ended never toasts: a realtime
 * failure stays on the stage as its failure card, the cascade shows errors in the failed message card. A [realtime]
 * start failure (the foreground service did not run) is its in-stage unknown card, never a toast.
 */
internal fun voiceConversationEventToast(
    event: VoiceConversationEvent,
    realtime: Boolean = false,
): Pair<Int, List<Any>>? = when (event) {
    is VoiceConversationEvent.StartFailed ->
        if (realtime) null else R.string.voice_conversation_start_failed_toast to emptyList()
    is VoiceConversationEvent.EngineFallback -> event.providerDisplayName
        ?.let { R.string.voice_read_aloud_cloud_fallback to listOf<Any>(it) }
        ?: (R.string.voice_read_aloud_engine_fallback to emptyList())
    is VoiceConversationEvent.TtsSelectionFallback -> R.string.voice_read_aloud_engine_fallback to emptyList()
    VoiceConversationEvent.PausedInBackground -> R.string.voice_conversation_background_paused_toast to emptyList()
    is VoiceConversationEvent.DraftTranscript, is VoiceConversationEvent.Ended, is VoiceConversationEvent.Haptic,
    VoiceConversationEvent.NudgeOrb,
    -> null
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
            captionState = mutableStateOf(""),
            nudgesState = mutableIntStateOf(0),
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

/**
 * Going back to the voice stage opens capture on the same connection ([RealtimeModel.backToStage], typingOpened): if the AI is speaking, first interrupt the playing reply as a tap on the orb does,
 * then open capture on the same connection; no new connection is opened.
 */
internal fun resumeCaptureBackToStage(engine: RealtimeVoiceConversationEngine) {
    val decision = RealtimeModel.backToStage(
        session = RealtimeModel.BACK_TO_STAGE_SESSION_TYPING_OPENED,
        assistantSpeaking = engine.statusKey.value == ConversationStatusKey.SPEAKING,
    )
    if (decision.interruptsPlayback) engine.tapOrb()
    engine.startCapture()
}

/** A realtime session opened by typing is running (playback only, capture not yet opened). */
internal fun typedRealtimeSessionRunning(engine: VoiceConversationEngine?): Boolean =
    (engine as? RealtimeVoiceConversationEngine)?.let { it.active.value && !it.capturing.value } == true

/**
 * Tapping back to the voice stage ([RealtimeModel.backToStage]): first exit typing mode; request only when a typing-opened session is running (the host opens capture on the same connection, interrupting speech first),
 * with no session, only the idle stage is shown and no session is opened.
 */
internal fun backToVoiceStage(typedSessionRunning: Boolean, leaveTyping: () -> Unit, request: () -> Unit) {
    leaveTyping()
    val session = if (typedSessionRunning) {
        RealtimeModel.BACK_TO_STAGE_SESSION_TYPING_OPENED
    } else {
        RealtimeModel.BACK_TO_STAGE_SESSION_NONE
    }
    if (RealtimeModel.backToStage(session).action == RealtimeModel.BACK_TO_STAGE_RESUME_CAPTURE) request()
}

/**
 * Sentence typed while awaiting the realtime disclosure reply: on consent [take] hands it back to resend; on decline / leaving the page, the matching outcome is reported and the original text stays in the input box. It is never dropped silently.
 */
internal class PendingTypedSend(private val report: (text: String, outcome: String) -> Unit) {
    private var text: String? = null

    fun hold(text: String) {
        this.text = text
    }

    /** Agreed: the sentence to send again; null = the disclosure came from ≋. */
    fun take(): String? = text.also { text = null }

    fun decline() = settle(RealtimeModel.TYPED_DISCLOSURE_DECLINED)

    fun leave() = settle(RealtimeModel.TYPED_HOST_LEFT)

    private fun settle(outcome: String) {
        val held = take() ?: return
        report(held, outcome)
    }
}

/**
 * A home conversation that ended before its first send gives up ownership (zero-round release); not once a chat
 * page took it over. Returns whether it was released on a failure.
 */
internal fun releaseHomeZeroTurn(port: VoiceConversationSessions.HandoffPort?, failure: RealtimeFailure?): Boolean {
    val home = port?.takeIf { it.target.value == null } ?: return false
    home.cancel()
    return failure != null
}

/**
 * The failure the stage shows: while this page owns the conversation; or after a home zero-round release on that
 * failure, until another page takes ownership — otherwise a tap on the orb that fails before the first turn looks
 * like nothing happened (a pre-turn failure is a card on the stage).
 */
/**
 * The failure belongs to the page's current realtime selection (same connection and model); another selection
 * (or none) hides it.
 */
internal fun failureMatchesSelection(failure: RealtimeFailure, selection: VoiceEngineSelection.Cloud?): Boolean =
    selection != null && selection.connectionId == failure.providerId && selection.model == failure.model

internal fun stageFailure(
    failure: RealtimeFailure?,
    owned: Boolean,
    releasedOnFailure: Boolean,
    sessions: VoiceConversationSessions,
): RealtimeFailure? = failure?.takeIf { owned || (releasedOnFailure && sessions.owner == null) }
