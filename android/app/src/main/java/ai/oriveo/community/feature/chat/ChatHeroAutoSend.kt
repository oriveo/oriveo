package ai.oriveo.community.feature.chat

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The longest back-off while waiting for the active model / draft to be ready. */
private const val HERO_AUTO_SEND_WAIT_MS = 1000
private const val HERO_AUTO_SEND_POLL_MS = 50

/**
 * Send-on-input from the home hero composer: once the conversation has loaded, wait for init to finish writing
 * activeProviderId / activeModelId / the draft, send once when all three are ready, and reuse the whole sendMessage chain.
 * A separate launch waits for all conditions to avoid races from collect ordering; the flag is also consumed on timeout so a rebuild does not trigger it again.
 */
internal fun CoroutineScope.launchHeroAutoSend(
    conversationLoaded: suspend () -> Unit,
    pending: () -> Boolean,
    ready: () -> Boolean,
    consume: () -> Unit,
    send: () -> Unit,
): Job = launch {
    conversationLoaded()
    var waitedMs = 0
    while (pending() && !ready() && waitedMs < HERO_AUTO_SEND_WAIT_MS) {
        delay(HERO_AUTO_SEND_POLL_MS.toLong())
        waitedMs += HERO_AUTO_SEND_POLL_MS
    }
    if (!pending()) return@launch
    consume()
    if (ready()) send()
}
