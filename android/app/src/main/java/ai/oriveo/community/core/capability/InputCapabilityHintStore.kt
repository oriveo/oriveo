package ai.oriveo.community.core.capability

import android.content.Context
import ai.oriveo.community.core.provider.OncePerModelHintStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

/**
 * One-time record for the light hint on first attachment (hint first_attach_once: once per model per device).
 * Keyed by `provider|model`, not by medium; implemented in [ai.oriveo.community.core.provider.OncePerModelHintStore].
 */
class InputCapabilityHintStore(
    readPayload: () -> String?,
    writePayload: (String?) -> Unit,
    ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : OncePerModelHintStore(readPayload, writePayload, ioDispatcher) {
    companion object {
        private const val PREFS_NAME = "input_capability_hint_seen.v1"

        fun from(context: Context): InputCapabilityHintStore {
            val payload = OncePerModelHintStore.PrefsPayload(context, PREFS_NAME)
            return InputCapabilityHintStore(readPayload = payload.read, writePayload = payload.write)
        }
    }
}
