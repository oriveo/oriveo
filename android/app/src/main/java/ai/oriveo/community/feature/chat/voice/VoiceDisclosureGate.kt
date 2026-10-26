package ai.oriveo.community.feature.chat.voice

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import ai.oriveo.community.core.app.AppPreferencesRepository
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.feature.chat.ProviderDisclosurePrompt
import kotlin.coroutines.cancellation.CancellationException

/** Whether a provider still needs its first-use disclosure, and accepting it (same rule as the chat send path). */
interface VoiceEntryDisclosure {
    suspend fun required(kind: ProviderKind): Boolean

    /** Records the acceptance; throws when it can't (e.g. the preference write fails). */
    suspend fun accept(kind: ProviderKind)
}

/** Production rule, identical to ChatSendCommandCoordinator.requiresDisclosure / confirmProviderDisclosure. */
class PreferencesVoiceEntryDisclosure(
    private val preferences: AppPreferencesRepository,
) : VoiceEntryDisclosure {
    override suspend fun required(kind: ProviderKind): Boolean = !preferences.hasAcceptedProviderDisclosure(kind)

    override suspend fun accept(kind: ProviderKind) {
        preferences.markProviderDisclosureAccepted(kind)
    }
}

/**
 * Home ≋ disclosure gate (same as the chat page's voice entry check): a provider that still needs its
 * disclosure shows the sheet instead of entering; accepting re-enters the voice conversation ([reenter]),
 * declining does nothing — no conversation, no conversation created.
 */
class VoiceDisclosureGate(
    private val disclosure: VoiceEntryDisclosure,
    private val reenter: () -> Unit,
    private val onAcceptFailed: (Throwable) -> Unit,
) {
    var prompt: ProviderDisclosurePrompt? by mutableStateOf(null)
        private set

    suspend fun allows(kind: ProviderKind): Boolean {
        if (!disclosure.required(kind)) return true
        prompt = ProviderDisclosurePrompt(kind = kind, displayName = kind.displayName, privacyPolicyUrl = kind.privacyPolicyUrl)
        return false
    }

    suspend fun confirm() {
        val shown = prompt ?: return
        try {
            disclosure.accept(shown.kind)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            onAcceptFailed(error)
            return
        }
        prompt = null
        reenter()
    }

    fun cancel() {
        prompt = null
    }
}
