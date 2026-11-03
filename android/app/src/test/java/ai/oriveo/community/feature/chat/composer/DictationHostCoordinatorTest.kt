package ai.oriveo.community.feature.chat.composer

import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalToastStyle
import ai.oriveo.community.core.voice.DictationCommands
import ai.oriveo.community.core.voice.DictationEngineInfo
import ai.oriveo.community.core.voice.DictationEvent
import ai.oriveo.community.core.voice.DictationState
import ai.oriveo.community.core.voice.DictationSubmit
import ai.oriveo.community.core.voice.LiveDictationRules
import ai.oriveo.community.core.voice.LiveTranscript
import ai.oriveo.community.core.voice.VoiceFallbackReason
import androidx.compose.ui.text.TextRange
import ai.oriveo.community.ui.component.ComposerSelectionProbe
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

/** Host coordinator event routing and card actions. */
class DictationHostCoordinatorTest {
    private val host = "conv:1"
    private val other = "conv:2"

    private class FakeCommands : DictationCommands {
        val calls = mutableListOf<String>()
        override val state = MutableStateFlow<DictationState>(DictationState.Idle)
        override val engineInfo = MutableStateFlow<DictationEngineInfo?>(null)
        override val pendingDurationSec = MutableStateFlow<Double?>(null)
        override val levelMeter = MutableStateFlow<List<Float>>(emptyList())
        override val boundOwner = MutableStateFlow<Any?>(null)

        override fun start(slotKey: String) {
            calls += "start:$slotKey"
        }

        override fun finish(submit: DictationSubmit) {
            calls += "finish:$submit"
        }

        override fun discard() {
            calls += "discard"
        }

        override fun transcribeSaved(submit: DictationSubmit) {
            calls += "transcribeSaved:$submit"
        }

        override fun discardAndRestart() {
            calls += "discardAndRestart"
        }

        override fun dismissDenied() {
            calls += "dismissDenied"
        }

        override fun undoDiscard(slotKey: String): Boolean {
            calls += "undoDiscard:$slotKey"
            return true
        }

        override fun bind(slotKey: String, owner: Any) {
            calls += "bind:$slotKey"
            boundOwner.value = owner
        }

        override fun detach(slotKey: String, owner: Any) {
            calls += "detach:$slotKey"
        }

        override fun downloadLanguagePack(language: String) {
            calls += "downloadLanguagePack:$language"
        }
    }

    private class FakeActions(var sendable: Boolean = true) : DictationHostActions {
        val calls = mutableListOf<String>()
        val toasts = mutableListOf<Pair<DictationToastSpec, (() -> Unit)?>>()

        override fun insert(text: String) {
            calls += "insert:$text"
        }

        override fun canSend(): Boolean = sendable

        override fun send() {
            calls += "send"
        }

        override fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?) {
            toasts += spec to onUndo
        }

        override fun openAppSettings() {
            calls += "openAppSettings"
        }

        override fun openProviderDetail(providerId: String) {
            calls += "openProviderDetail:$providerId"
        }

        override fun openProviderSetup() {
            calls += "openProviderSetup"
        }

        override fun openVoiceSettings() {
            calls += "openVoiceSettings"
        }
    }

    private val commands = FakeCommands()
    private val actions = FakeActions()
    private val coordinator = DictationHostCoordinator(host, commands, actions)

    @Test
    fun `events of other slots are ignored`() {
        listOf(
            DictationEvent.Insert(other, "a"),
            DictationEvent.Send(other, "b"),
            DictationEvent.NoSpeech(other),
            DictationEvent.DiscardUndoable(other),
            DictationEvent.SystemUnavailable(other),
        ).forEach(coordinator::onEvent)
        assertEquals(emptyList<String>(), actions.calls)
        assertTrue(actions.toasts.isEmpty())
        assertEquals(emptyList<String>(), commands.calls)
    }

    @Test
    fun `insert event inserts the text`() {
        coordinator.onEvent(DictationEvent.Insert(host, "hello"))
        assertEquals(listOf("insert:hello"), actions.calls)
        assertTrue(actions.toasts.isEmpty())
    }

    @Test
    fun `send event inserts then sends when the host can send`() {
        coordinator.onEvent(DictationEvent.Send(host, "hi"))
        assertEquals(listOf("insert:hi", "send"), actions.calls)
    }

    @Test
    fun `send event only inserts when the host cannot send`() {
        actions.sendable = false
        coordinator.onEvent(DictationEvent.Send(host, "hi"))
        assertEquals(listOf("insert:hi"), actions.calls)
    }

    @Test
    fun `toast events follow the contract specs`() {
        listOf(
            DictationEvent.NoSpeech(host),
            DictationEvent.EngineFallback(host, VoiceFallbackReason.KeyMissing),
            DictationEvent.SystemUnavailable(host),
            DictationEvent.RecordingUnavailable(host),
        ).forEach(coordinator::onEvent)
        assertEquals(
            listOf(
                DictationToastSpec(R.string.voice_dictation_no_speech, GlobalToastStyle.Info, 3_000L),
                DictationToastSpec(R.string.voice_dictation_engine_fallback, GlobalToastStyle.Info, 3_000L),
                DictationToastSpec(
                    message = R.string.voice_dictation_system_unavailable,
                    style = GlobalToastStyle.Warning,
                    durationMillis = 6_000L,
                    actionLabel = R.string.voice_settings_action,
                    action = DictationToastAction.OpenVoiceSettings,
                ),
                DictationToastSpec(R.string.voice_dictation_recording_unavailable, GlobalToastStyle.Error, 3_000L),
            ),
            actions.toasts.map { it.first },
        )
        // Only the system-unavailable toast carries a button callback.
        assertEquals(listOf(false, false, true, false), actions.toasts.map { it.second != null })
        assertEquals(emptyList<String>(), actions.calls)
    }

    @Test
    fun `system unavailable action opens voice settings`() {
        coordinator.onEvent(DictationEvent.SystemUnavailable(host))
        val (spec, onAction) = actions.toasts.single()
        assertEquals(R.string.voice_settings_action, spec.actionLabel)
        assertEquals(DictationToastAction.OpenVoiceSettings, spec.action)
        assertEquals(emptyList<String>(), actions.calls)
        assertNotNull(onAction)
        onAction!!.invoke()
        assertEquals(listOf("openVoiceSettings"), actions.calls)
        assertEquals(emptyList<String>(), commands.calls)
    }

    @Test
    fun `language pack offer shows the prompt with a download button`() {
        val coordinator = DictationHostCoordinator(host, commands, actions, uiLocale = { Locale.ENGLISH })
        coordinator.onEvent(DictationEvent.LanguagePackOffer("fr-FR"))
        val (spec, onAction) = actions.toasts.single()
        assertEquals(
            DictationToastSpec(
                message = R.string.voice_language_pack_prompt,
                style = GlobalToastStyle.Info,
                durationMillis = 6_000L,
                actionLabel = R.string.voice_language_pack_download,
                action = DictationToastAction.DownloadLanguagePack,
                messageArgs = listOf("French (France)"),
            ),
            spec,
        )
        assertNotNull(onAction)
        assertEquals(emptyList<String>(), commands.calls)
        assertEquals(emptyList<String>(), actions.calls)
    }

    @Test
    fun `language pack download calls the controller and says it is downloading`() {
        val coordinator = DictationHostCoordinator(host, commands, actions, uiLocale = { Locale.ENGLISH })
        coordinator.onEvent(DictationEvent.LanguagePackOffer("fr-FR"))
        actions.toasts.single().second!!.invoke()
        assertEquals(listOf("downloadLanguagePack:fr-FR"), commands.calls)
        assertEquals(2, actions.toasts.size)
        val (spec, onAction) = actions.toasts[1]
        assertEquals(
            DictationToastSpec(
                message = R.string.voice_language_pack_downloading,
                style = GlobalToastStyle.Info,
                durationMillis = 6_000L,
                messageArgs = listOf("French (France)"),
            ),
            spec,
        )
        assertNull(onAction)
    }

    @Test
    fun `discard undoable toast undo calls undoDiscard for the slot`() {
        coordinator.onEvent(DictationEvent.DiscardUndoable(host))
        val (spec, onUndo) = actions.toasts.single()
        assertEquals(
            DictationToastSpec(
                message = R.string.voice_dictation_discarded,
                style = GlobalToastStyle.Removed,
                durationMillis = 4_000L,
                undoSlotKey = host,
                undoLabel = R.string.voice_dictation_undo,
            ),
            spec,
        )
        assertEquals(emptyList<String>(), commands.calls)
        assertNotNull(onUndo)
        onUndo!!.invoke()
        assertEquals(listOf("undoDiscard:$host"), commands.calls)
    }

    @Test
    fun `card actions call the right commands`() {
        val expected =
            mapOf(
                DictationCardAction.Discard to listOf("discard"),
                DictationCardAction.Retry to listOf("transcribeSaved:Insert"),
                DictationCardAction.TranscribeRecording to listOf("transcribeSaved:Insert"),
                DictationCardAction.TranscribeFirst to listOf("transcribeSaved:Insert"),
                DictationCardAction.DiscardAndRerecord to listOf("discardAndRestart"),
                DictationCardAction.NotNow to listOf("dismissDenied"),
            )
        expected.forEach { (action, calls) ->
            commands.calls.clear()
            coordinator.onCardAction(action)
            assertEquals(action.name, calls, commands.calls)
        }
        assertEquals(emptyList<String>(), actions.calls)

        commands.calls.clear()
        coordinator.onCardAction(DictationCardAction.OpenSettings)
        assertEquals(listOf("openAppSettings"), actions.calls)
        assertEquals(emptyList<String>(), commands.calls)
    }

    @Test
    fun `change language opens the in-page picker and switch engine opens voice settings`() {
        // Changing the recognition language opens a form on the current page; only switching the engine goes to settings
        coordinator.onCardAction(DictationCardAction.ChangeLanguage)
        assertTrue(coordinator.languagePickerOpen.value)
        assertEquals(emptyList<String>(), actions.calls)
        coordinator.onCardAction(DictationCardAction.SwitchEngine)
        assertEquals(listOf("openVoiceSettings"), actions.calls)
        assertEquals(emptyList<String>(), commands.calls)
    }

    @Test
    fun `check connection opens provider detail when engine has a provider id`() {
        commands.engineInfo.value = DictationEngineInfo(displayName = "Whisper", providerId = "prov-1", isCloud = true)
        coordinator.onCardAction(DictationCardAction.CheckConnection)
        assertEquals(listOf("openProviderDetail:prov-1"), actions.calls)
    }

    @Test
    fun `check connection opens provider setup without a provider id`() {
        coordinator.onCardAction(DictationCardAction.CheckConnection)
        commands.engineInfo.value = DictationEngineInfo.System
        coordinator.onCardAction(DictationCardAction.CheckConnection)
        assertEquals(listOf("openProviderSetup", "openProviderSetup"), actions.calls)
        assertNull(commands.engineInfo.value?.providerId)
    }

    @Test
    fun `mic tap starts dictation on the host slot`() {
        coordinator.onMicTap()
        assertEquals(listOf("bind:$host", "start:$host"), commands.calls)
        assertSame(coordinator.owner, commands.boundOwner.value)
    }

    @Test
    fun `mic tap only starts when this owner is already bound`() {
        commands.boundOwner.value = coordinator.owner
        coordinator.onMicTap()
        assertEquals(listOf("start:$host"), commands.calls)
    }

    // ── Live dictation range: the host writes into the input via ComposerSelectionProbe ──

    /** Host that holds the input text with a real probe, wired the same way as ChatComposerHost / HomeScreen. */
    private class LiveActions(var text: String, caret: Int) : DictationHostActions {
        val probe = ComposerSelectionProbe().apply { record(TextRange(caret)) }
        val calls = mutableListOf<String>()

        override fun insert(text: String) {
            this.text = probe.insert(text, this.text)
        }

        override fun canSend(): Boolean = true

        override fun send() {
            calls += "send:$text"
        }

        override fun showToast(spec: DictationToastSpec, onUndo: (() -> Unit)?) {
            calls += "toast"
        }

        override fun openAppSettings() = Unit

        override fun openProviderDetail(providerId: String) = Unit

        override fun openProviderSetup() = Unit

        override fun openVoiceSettings() = Unit

        override fun beginLive() = probe.beginLive(text)

        override fun updateLive(finals: List<String>, partial: String) {
            text = probe.updateLive(finals, partial, text)
        }

        override fun retractLive() {
            text = probe.retractLive(text)
        }
    }

    private val live = LiveActions("hello world", caret = 5)
    private val liveCoordinator = DictationHostCoordinator(host, commands, live)

    @Test
    fun `live partial is written at the caret where dictation started`() {
        commands.state.value = DictationState.Recording(host, 0L)

        liveCoordinator.onLivePartial(LiveTranscript())
        assertEquals("hello world", live.text)
        liveCoordinator.onLivePartial(LiveTranscript(listOf("there"), "yo"))
        assertEquals(LiveDictationRules.liveInsert("hello world", 5, 5, listOf("there"), "yo").text, live.text)
        liveCoordinator.onLivePartial(LiveTranscript(listOf("there"), "you"))
        assertEquals("hello there you world", live.text)
    }

    @Test
    fun `insert replaces the live region and send sends after it`() {
        liveCoordinator.onLivePartial(LiveTranscript(listOf("thee"), "yu"))
        liveCoordinator.onLivePartial(null)

        liveCoordinator.onEvent(DictationEvent.Insert(host, "there you"))
        assertEquals("hello there you world", live.text)

        // The next dictation segment reopens the range on the new text; Send replaces first, then sends.
        liveCoordinator.onLivePartial(LiveTranscript(listOf("ok"), ""))
        liveCoordinator.onEvent(DictationEvent.Send(host, "okay"))
        assertEquals(LiveDictationRules.liveInsert("hello there you world", 15, 15, listOf("okay"), "").text, live.text)
        assertEquals(listOf("send:${live.text}"), live.calls)
    }

    @Test
    fun `live retract deletes the region and restores the original text`() {
        liveCoordinator.onLivePartial(LiveTranscript(listOf("there"), ""))
        assertEquals("hello there world", live.text)

        liveCoordinator.onEvent(DictationEvent.LiveRetract(other))
        assertEquals("hello there world", live.text)
        liveCoordinator.onEvent(DictationEvent.LiveRetract(host))
        assertEquals("hello world", live.text)
        assertEquals(TextRange(5), live.probe.selection)
        assertTrue(live.calls.isEmpty())
    }

    @Test
    fun `live partial while another slot records is ignored`() {
        commands.state.value = DictationState.Recording(other, 0L)

        liveCoordinator.onLivePartial(LiveTranscript(listOf("there"), ""))

        assertEquals("hello world", live.text)
    }

    @Test
    fun `host detached with a live region restores the original text`() {
        liveCoordinator.onLivePartial(LiveTranscript(listOf("there"), "you"))
        assertEquals("hello there you world", live.text)

        liveCoordinator.onLiveDetached()

        assertEquals("hello world", live.text)
    }
}
