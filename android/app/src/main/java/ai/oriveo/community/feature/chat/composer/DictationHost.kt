package ai.oriveo.community.feature.chat.composer

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.app.ActivityCompat
import ai.oriveo.community.core.voice.AndroidMicrophonePermission
import ai.oriveo.community.core.voice.DictationCommands
import ai.oriveo.community.core.voice.DictationController
import ai.oriveo.community.core.voice.DictationEvent
import ai.oriveo.community.core.voice.DictationState
import ai.oriveo.community.core.voice.DictationSubmit
import ai.oriveo.community.core.voice.KeepScreenOnHolds
import ai.oriveo.community.ui.util.findActivity
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.map
import org.koin.mp.KoinPlatform

/**
 * Capabilities on the host (composer) side: insert, send, toast, navigation. Implemented by the Composable host; the coordinator only touches the UI through it.
 */
interface DictationHostActions {
    /** Insert text at the current selection: with a selection, insert after its end and keep the selected text (no replace); otherwise insert at the cursor. */
    fun insert(text: String)

    /** Whether the host can take the normal send path right now (same availability as the send key). */
    fun canSend(): Boolean

    /** Take the host's normal send path. */
    fun send()

    /** Show a toast; when [onUndo] is non-null a button is shown (undo or the [DictationToastSpec.action] action) and invokes it on tap. */
    fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?)

    /** Open this app's system app-details settings page (package:this package). */
    fun openAppSettings()

    /** Open the detail page of a provider connection. */
    fun openProviderDetail(providerId: String)

    /** Open the add-provider flow. */
    fun openProviderSetup()

    /** Open the voice settings page. */
    fun openVoiceSettings()
}

/**
 * Dictation host coordinator: routes controller events to the host and runs card button actions.
 * Only handles events of its own [hostSlotKey] slot; pure logic, no Compose.
 * [hostSlotKey] and [commands] are public so observing components (DictationInputSwitcher / DictationPromptSlot) can read state.
 * [owner] is the identity of the host instance: bind / detach / mic taps all carry it, and only when [DictationCommands.boundOwner] equals it is it the current host.
 */
class DictationHostCoordinator(
    val hostSlotKey: String,
    val commands: DictationCommands,
    private val actions: DictationHostActions,
    val owner: Any = Any(),
) {
    /** Controller events: Insert inserts; Send inserts first, then sends if the host can; the rest show toasts per spec. Other slots are ignored. */
    fun onEvent(event: DictationEvent) {
        when (event) {
            is DictationEvent.Insert -> if (event.slotKey == hostSlotKey) actions.insert(event.text)
            is DictationEvent.Send ->
                if (event.slotKey == hostSlotKey) {
                    actions.insert(event.text)
                    if (actions.canSend()) actions.send()
                }
            else -> {
                val spec = dictationToast(event, hostSlotKey) ?: return
                val undoKey = spec.undoSlotKey
                val onUndo: (() -> Unit)? = undoKey?.let { key -> { commands.undoDiscard(key) } }
                    ?: spec.action?.let { action ->
                        when (action) {
                            DictationToastAction.OpenVoiceSettings -> { { actions.openVoiceSettings() } }
                        }
                    }
                actions.showToast(spec, onUndo)
            }
        }
    }

    /** Card buttons: retry / transcribe recording / transcribe first all insert the transcript, never send directly. */
    fun onCardAction(action: DictationCardAction) {
        when (action) {
            DictationCardAction.Discard -> commands.discard()
            DictationCardAction.Retry,
            DictationCardAction.TranscribeRecording,
            DictationCardAction.TranscribeFirst,
            -> commands.transcribeSaved(DictationSubmit.Insert)
            DictationCardAction.DiscardAndRerecord -> commands.discardAndRestart()
            DictationCardAction.NotNow -> commands.dismissDenied()
            DictationCardAction.OpenSettings -> actions.openAppSettings()
            DictationCardAction.CheckConnection -> {
                val providerId = commands.engineInfo.value?.providerId
                if (providerId != null) actions.openProviderDetail(providerId) else actions.openProviderSetup()
            }
        }
    }

    /** Mic tap: start recording in this slot; when the current host is not this instance (including no host), bind this slot with this instance's identity first so events come back to this host. */
    fun onMicTap() {
        if (commands.boundOwner.value !== owner) commands.bind(hostSlotKey, owner)
        commands.start(hostSlotKey)
    }
}

/**
 * Attach the dictation coordinator to the host lifecycle: bind this slot on entering composition, rebuild and rebind on slot change, detach on leaving composition (no detach when an Activity is recreated for a config change).
 * Each host instance remembers an identity used by bind / detach: if a new host with the same key binds first and the old one detaches later, the binding stays with the new host.
 * [events] is a single-consumer channel; only the current host ([DictationCommands.boundOwner] is this instance) collects it and hands it to the coordinator to route to [actions];
 * the collector switches when the owner changes, so other instances never take events. Also attaches the system microphone permission requester to [AndroidMicrophonePermission].
 * The screen stays on while this host is current and the controller records in this slot, following controller state rather than whether the recording bar is in composition:
 * the home recording bar lives in a LazyColumn item, and scrolling it off screen does not restore early.
 * If no controller can be obtained (Koin not started / not registered, UI unit tests, Preview) returns null: the host shows no microphone.
 * [events] defaults to [DictationController.events]; tests injecting fake [commands] pass it explicitly.
 */
@Composable
fun rememberDictationHost(
    slotKey: String,
    actions: DictationHostActions,
    commands: DictationCommands? = rememberKoinDictationController(),
    events: Flow<DictationEvent> = remember(commands) { (commands as? DictationController)?.events ?: emptyFlow() },
): DictationHostCoordinator? {
    if (commands == null) return null
    val currentActions by rememberUpdatedState(actions)
    val owner = remember { Any() }
    val coordinator = remember(slotKey, commands) {
        DictationHostCoordinator(slotKey, commands, LatestDictationHostActions { currentActions }, owner)
    }
    val context = LocalContext.current

    LaunchedEffect(slotKey, commands) { commands.bind(slotKey, owner) }
    DisposableEffect(slotKey, commands) {
        onDispose {
            if (context.findActivity()?.isChangingConfigurations != true) commands.detach(slotKey, owner)
        }
    }
    LaunchedEffect(coordinator, events) {
        commands.boundOwner
            .map { it === owner }
            .distinctUntilChanged()
            .collectLatest { bound -> if (bound) events.collect(coordinator::onEvent) }
    }
    val view = LocalView.current
    LaunchedEffect(slotKey, commands, view) {
        // Hold keep-screen-on while recording (shares the per-View hold count with read-aloud; the original value is restored only when the last hold ends).
        val holds = KeepScreenOnHolds.views
        try {
            combine(commands.state, commands.boundOwner) { state, bound ->
                bound === owner && state is DictationState.Recording && state.slotKey == slotKey
            }
                .distinctUntilChanged()
                .collect { recording ->
                    if (recording) holds.acquire(view, owner) else holds.release(view, owner)
                }
        } finally {
            holds.release(view, owner)
        }
    }

    MicrophonePermissionRequester()
    return coordinator
}

/** Gets the dictation controller from Koin during composition; null if Koin is not started or not registered (same as [ai.oriveo.community.ui.component.rememberGlobalSnackbarManager]). */
@Composable
private fun rememberKoinDictationController(): DictationCommands? =
    remember { KoinPlatform.getKoinOrNull()?.getOrNull<DictationController>() }

/**
 * Attach the RECORD_AUDIO requester to the production permission object; close on leaving, ending pending requests as denied. Not attached if the permission object is unavailable.
 * On an Activity recreation for a config change use releaseForConfigChange instead: the request in the permission dialog is left to the requester after recreation,
 * and the result the launcher receives after recreation by its saved key completes it via onResult.
 */
@Composable
private fun MicrophonePermissionRequester() {
    val permission = remember { KoinPlatform.getKoinOrNull()?.getOrNull<AndroidMicrophonePermission>() } ?: return
    val pending = remember { PendingPermissionCallback() }
    val handleHolder = remember { arrayOfNulls<AndroidMicrophonePermission.RequesterHandle>(1) }
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        pending.take()?.invoke(granted)
        handleHolder[0]?.onResult(granted)
    }
    val currentLauncher by rememberUpdatedState(launcher)
    val context = LocalContext.current
    DisposableEffect(permission) {
        val handle = permission.attach(
            shouldShowRationale = {
                context.findActivity()?.let {
                    ActivityCompat.shouldShowRequestPermissionRationale(it, Manifest.permission.RECORD_AUDIO)
                } ?: false
            },
        ) { callback ->
            pending.put(callback)
            currentLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
        handleHolder[0] = handle
        onDispose {
            handleHolder[0] = null
            if (context.findActivity()?.isChangingConfigurations == true) handle.releaseForConfigChange() else handle.close()
            pending.take()
        }
    }
}

/** Callback awaiting the system permission result; the system returns one result at a time, so when a later request arrives the unanswered one is ended as denied. */
private class PendingPermissionCallback {
    private var callback: ((Boolean) -> Unit)? = null

    fun put(value: (Boolean) -> Unit) {
        val previous = callback
        callback = value
        previous?.invoke(false)
    }

    fun take(): ((Boolean) -> Unit)? = callback.also { callback = null }
}

/** The coordinator is rebuilt per slot and host actions may change instance on each recomposition: forward to the latest one. */
private class LatestDictationHostActions(private val latest: () -> DictationHostActions) : DictationHostActions {
    override fun insert(text: String) = latest().insert(text)

    override fun canSend(): Boolean = latest().canSend()

    override fun send() = latest().send()

    override fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?) = latest().showToast(spec, onUndo)

    override fun openAppSettings() = latest().openAppSettings()

    override fun openProviderDetail(providerId: String) = latest().openProviderDetail(providerId)

    override fun openProviderSetup() = latest().openProviderSetup()

    override fun openVoiceSettings() = latest().openVoiceSettings()
}
