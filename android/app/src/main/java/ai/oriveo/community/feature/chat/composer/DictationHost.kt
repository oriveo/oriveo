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
import androidx.compose.ui.platform.LocalConfiguration
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
import ai.oriveo.community.core.voice.LiveTranscript
import ai.oriveo.community.ui.util.findActivity
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import org.koin.mp.KoinPlatform
import java.util.Locale

/**
 * Capabilities on the host (composer) side: insert, send, toast, navigation. Implemented by the Composable host; the coordinator only touches the UI through it.
 */
interface DictationHostActions {
    /** Insert at the current selection: with a selection, insert after its end and keep the selected text (no replace); otherwise insert at the cursor. */
    fun insert(text: String)

    /** Whether the host can take the normal send path right now (same availability as the send key). */
    fun canSend(): Boolean

    /** Take the host's normal send path. */
    fun send()

    /** Show a toast; when [onUndo] is non-null a button is shown (undo, or the [DictationToastSpec.action] action) and invokes it on tap. */
    fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?)

    /** Open this app's system app-details settings page (package: this package). */
    fun openAppSettings()

    /** Open the detail page of a provider connection. */
    fun openProviderDetail(providerId: String)

    /** Open the add-provider flow. */
    fun openProviderSetup()

    /** Open the voice settings page. */
    fun openVoiceSettings()

    /** Start a live-text dictation range: record the original text and selection at this moment (any earlier range is no longer tracked). Live text is unsupported by default. */
    fun beginLive() {}

    /** Recompute the range from [finals] and [partial] against the original text and write it back to the input; the input is read-only while tracking. */
    fun updateLive(finals: List<String>, partial: String) {}

    /** Remove the live range; the original text and selection are restored. Does nothing when there is no range. */
    fun retractLive() {}
}

/**
 * Dictation host coordinator: routes controller events to the host and runs card button actions.
 * Only handles events of this slot ([hostSlotKey]); pure logic, no Compose.
 * [hostSlotKey] and [commands] are exposed to observing components (DictationInputSwitcher / DictationPromptSlot) to read state.
 * [owner] is the identity of the host instance: bind / detach / mic taps all carry it; only when [DictationCommands.boundOwner] equals it is it the current host.
 */
class DictationHostCoordinator(
    val hostSlotKey: String,
    val commands: DictationCommands,
    private val actions: DictationHostActions,
    val owner: Any = Any(),
    /** UI language: the recognition language name in the language-pack hint is taken from it (same lookup as the failure card). */
    private val uiLocale: () -> Locale = { Locale.getDefault() },
) {
    /** Whether the last live text received was non-null: null → non-null starts a new range. */
    private var followingLive = false

    private val _languagePickerOpen = MutableStateFlow(false)

    /** After the user taps "change recognition language" on the failure card this is true: [DictationPromptSlot] then shows the recognition-language form on the current page. */
    val languagePickerOpen: StateFlow<Boolean> = _languagePickerOpen.asStateFlow()

    /**
     * Live text from the controller ([DictationCommands.livePartial]): when it turns non-null a range starts, and each non-null value recomputes and writes the whole range;
     * when it turns null only this follow stops; the range stays for the following Insert / Send to replace, or for LiveRetract to remove. Ignored while the controller is on another slot.
     */
    fun onLivePartial(transcript: LiveTranscript?) {
        if (transcript == null) {
            followingLive = false
            return
        }
        if (activeSlotKey(commands.state.value)?.let { it != hostSlotKey } == true) return
        if (!followingLive) {
            followingLive = true
            actions.beginLive()
        }
        actions.updateLive(transcript.finals, transcript.partial)
    }

    /** This host no longer receives live text (the current host changed or it left composition): if a range is still present, the original text is restored. */
    fun onLiveDetached() {
        followingLive = false
        actions.retractLive()
    }

    /**
     * Controller events: Insert inserts (replacing the live range if there is one); Send inserts first too, and sends only if the host can send;
     * LiveRetract removes the live range; LanguagePackOffer shows a hint with a download button (not per slot; the controller guarantees once per language);
     * the rest show toasts per spec. Other slots are ignored.
     */
    fun onEvent(event: DictationEvent) {
        when (event) {
            is DictationEvent.LiveRetract -> if (event.slotKey == hostSlotKey) actions.retractLive()
            is DictationEvent.Insert -> if (event.slotKey == hostSlotKey) actions.insert(event.text)
            is DictationEvent.Send ->
                if (event.slotKey == hostSlotKey) {
                    actions.insert(event.text)
                    if (actions.canSend()) actions.send()
                }
            is DictationEvent.LanguagePackOffer -> offerLanguagePack(event.language)
            else -> {
                val spec = dictationToast(event, hostSlotKey) ?: return
                val undoKey = spec.undoSlotKey
                val onUndo: (() -> Unit)? = undoKey?.let { key -> { commands.undoDiscard(key) } }
                    ?: spec.action?.let { action ->
                        when (action) {
                            DictationToastAction.OpenVoiceSettings -> { { actions.openVoiceSettings() } }
                            // The language-pack hint does not go through dictationToast; it carries its own callback via offerLanguagePack.
                            DictationToastAction.DownloadLanguagePack -> null
                        }
                    }
                actions.showToast(spec, onUndo)
            }
        }
    }

    /** Language-pack prompt: tapping download starts the download, then shows that a download is in progress (no button). */
    private fun offerLanguagePack(language: String) {
        val name = languageName(language, uiLocale())
        actions.showToast(languagePackOfferToast(name)) {
            commands.downloadLanguagePack(language)
            actions.showToast(languagePackDownloadingToast(name), null)
        }
    }

    /**
     * Card buttons: retry / transcribe recording / transcribe first all insert the transcript and never send directly; change recognition language opens the recognition-language form on the current page,
     * and change dictation engine opens the voice settings page.
     */
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
            DictationCardAction.ChangeLanguage -> _languagePickerOpen.value = true
            DictationCardAction.SwitchEngine -> actions.openVoiceSettings()
            DictationCardAction.CheckConnection -> {
                val providerId = commands.engineInfo.value?.providerId
                if (providerId != null) actions.openProviderDetail(providerId) else actions.openProviderSetup()
            }
        }
    }

    /**
     * On closing the recognition-language form: if [changed] is true and this slot's failure card still holds the recording, follow the same path as retry (reads the newly saved language when transcribing);
     * if not changed or there is no recording, only the form collapses and the card stays as it is.
     */
    fun closeLanguagePicker(changed: Boolean) {
        _languagePickerOpen.value = false
        if (!changed) return
        val state = commands.state.value
        if (state is DictationState.Failed && state.slotKey == hostSlotKey && state.hasRecording) {
            onCardAction(DictationCardAction.Retry)
        }
    }

    private fun activeSlotKey(state: DictationState): String? = when (state) {
        is DictationState.Recording -> state.slotKey
        is DictationState.Transcribing -> state.slotKey
        else -> null
    }

    /**
     * Mic tap: start recording in this slot. When the current host is not this instance (including no host), first bind this slot with this instance's identity so events come back to this host.
     * No new dictation starts while the recognition-language form is open.
     */
    fun onMicTap() {
        if (_languagePickerOpen.value) return
        if (commands.boundOwner.value !== owner) commands.bind(hostSlotKey, owner)
        commands.start(hostSlotKey)
    }
}

/**
 * Attach the dictation coordinator to the host lifecycle: bind this slot on entering composition, rebind to the new slot on slot change, detach on leaving composition (no detach on a config-change Activity recreation).
 * Each host instance remembers an identity used by bind / detach: if a new host with the same key binds first and the old one detaches later, the binding stays with the new host.
 * [events] is a single-consumer channel; only the current host ([DictationCommands.boundOwner] is this instance) collects it and routes it to [actions] via the coordinator;
 * the collector switches when the owner changes, so other instances never take events. Live text ([DictationCommands.livePartial]) is likewise collected only by the current host;
 * if the host stops being current or leaves composition while a range is still present, the original text is restored. Also attaches the system microphone permission requester to [AndroidMicrophonePermission].
 * The screen stays on while this host is current and the controller records in this slot. It follows controller state, not whether the recording bar is in composition:
 * the home recording bar lives in a LazyColumn item, so scrolling it off screen does not restore early.
 * If no controller can be obtained (Koin not started or not registered, UI unit tests, Preview), returns null: the host shows no microphone.
 * [events] defaults to [DictationController.events]; tests injecting a fake [commands] pass it explicitly.
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
    val uiLocale by rememberUpdatedState(LocalConfiguration.current.locales[0])
    val owner = remember { Any() }
    val coordinator = remember(slotKey, commands) {
        DictationHostCoordinator(slotKey, commands, LatestDictationHostActions { currentActions }, owner) { uiLocale }
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
            .collectLatest { bound ->
                if (!bound) return@collectLatest
                try {
                    coroutineScope {
                        launch { commands.livePartial.collect(coordinator::onLivePartial) }
                        events.collect(coordinator::onEvent)
                    }
                } finally {
                    coordinator.onLiveDetached()
                }
            }
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
 * Attach the RECORD_AUDIO requester to the production permission object; close on leaving, pending requests end as denied. Not attached when the permission object cannot be obtained.
 * On an Activity recreation for a config change, releaseForConfigChange is used instead: a request in the permission dialog is left to the requester after recreation,
 * and the result the launcher receives under the saved key after recreation completes it via onResult.
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

/** Callback for the system permission result; the system returns one result at a time, so when a later request arrives, the unanswered one is ended as denied. */
private class PendingPermissionCallback {
    private var callback: ((Boolean) -> Unit)? = null

    fun put(value: (Boolean) -> Unit) {
        val previous = callback
        callback = value
        previous?.invoke(false)
    }

    fun take(): ((Boolean) -> Unit)? = callback.also { callback = null }
}

/** The coordinator is rebuilt per slot, and host actions may change instance on each recomposition: forwards to the latest one. */
private class LatestDictationHostActions(private val latest: () -> DictationHostActions) : DictationHostActions {
    override fun insert(text: String) = latest().insert(text)

    override fun canSend(): Boolean = latest().canSend()

    override fun send() = latest().send()

    override fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?) = latest().showToast(spec, onUndo)

    override fun openAppSettings() = latest().openAppSettings()

    override fun openProviderDetail(providerId: String) = latest().openProviderDetail(providerId)

    override fun openProviderSetup() = latest().openProviderSetup()

    override fun openVoiceSettings() = latest().openVoiceSettings()

    override fun beginLive() = latest().beginLive()

    override fun updateLive(finals: List<String>, partial: String) = latest().updateLive(finals, partial)

    override fun retractLive() = latest().retractLive()
}
