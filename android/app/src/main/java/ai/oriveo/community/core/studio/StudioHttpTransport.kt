package ai.oriveo.community.core.studio

import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/**
 * Executes a Studio BYOK request with a call-level total timeout: DNS, connect, writing
 * the body, provider processing and reading the response all count against one budget.
 * The shared chat client only has socket timeouts (long streams must not be cut), so
 * Studio sets the budget per call here.
 */
class StudioHttpTransport(
    private val client: OkHttpClient,
    private val isCompiledIn: Boolean = StudioAvailability.compiledIn,
) {
    /** Builds the call with its total timeout applied; the timer starts at execute(). Null when Studio is compiled out. */
    fun newCall(request: Request, timeoutSeconds: Int?): Call? {
        if (!isCompiledIn) return null
        return client.newCall(request).also {
            it.timeout().timeout(totalTimeoutSeconds(timeoutSeconds).toLong(), TimeUnit.SECONDS)
        }
    }

    /** Throws InterruptedIOException("timeout") once the total budget is spent. Null when compiled out. */
    fun execute(request: Request, timeoutSeconds: Int?): Response? =
        newCall(request, timeoutSeconds)?.execute()

    companion object {
        const val DEFAULT_TIMEOUT_SECONDS = 180

        /**
         * Missing or non-positive profile values fall back to 180 s, and nothing may exceed
         * 180 s: the shortService window that hosts the call is about 3 minutes.
         */
        fun totalTimeoutSeconds(profileSeconds: Int?): Int =
            if (profileSeconds == null || profileSeconds <= 0) DEFAULT_TIMEOUT_SECONDS
            else minOf(profileSeconds, DEFAULT_TIMEOUT_SECONDS)
    }
}
