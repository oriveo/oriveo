package ai.oriveo.community.core.studio

import ai.oriveo.community.core.studio.StudioImageResponse.Failure
import ai.oriveo.community.core.studio.StudioImageResponse.Outcome
import ai.oriveo.community.core.util.InputSizeLimitExceededException
import ai.oriveo.community.core.util.readBytesLimited
import java.io.IOException
import java.io.InterruptedIOException
import java.util.concurrent.TimeUnit
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/**
 * Downloads URL images right away (provider URLs expire). One call-level budget covers the
 * whole download; the body is read with a hard byte cap; Content-Type is not trusted, the
 * header decode decides. Policy constants mirror image_response_samples.v1 fetchPolicy.
 */
class StudioImageFetcher(
    private val client: OkHttpClient,
    private val maxBytes: Long = MAX_BYTES,
    private val timeout: Duration = TIMEOUT_SECONDS.seconds,
) {
    /**
     * Timeouts map to timeout, other transport errors and non-2xx to network, oversize / non-image / non-http to decode_failed.
     * Cancelling the coroutine cancels the call at once, which disconnects the socket mid-download.
     */
    suspend fun fetch(url: String): Outcome {
        if (url.substringBefore(':', "").lowercase() !in SCHEMES) return Outcome.Failed(Failure.DECODE_FAILED)
        val httpUrl = url.toHttpUrlOrNull() ?: return Outcome.Failed(Failure.DECODE_FAILED)
        val call = client.newCall(Request.Builder().url(httpUrl).get().build())
        call.timeout().timeout(timeout.inWholeMilliseconds, TimeUnit.MILLISECONDS)
        return suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    continuation.resume(failureOf(e))
                }

                override fun onResponse(call: Call, response: Response) {
                    val result = runCatching { response.use { read(it) } }
                    result.exceptionOrNull()?.let { error ->
                        if (error is IOException) continuation.resume(failureOf(error)) else continuation.resumeWithException(error)
                        return
                    }
                    continuation.resume(result.getOrThrow())
                }
            })
        }
    }

    /** Runs on the OkHttp dispatcher thread; the call timeout and cancel both interrupt the body read. */
    private fun read(response: Response): Outcome {
        if (!response.isSuccessful) return Outcome.Failed(Failure.NETWORK)
        val body = response.body
        val length = body.contentLength()
        if (length > maxBytes) return Outcome.Failed(Failure.DECODE_FAILED)
        return StudioImageResponse.outcomeOf(body.byteStream().use { it.readBytesLimited(maxBytes, length) })
    }

    private fun failureOf(e: IOException): Outcome = when (e) {
        is InputSizeLimitExceededException -> Outcome.Failed(Failure.DECODE_FAILED)
        is InterruptedIOException -> Outcome.Failed(Failure.TIMEOUT)
        else -> Outcome.Failed(Failure.NETWORK)
    }

    companion object {
        const val MAX_BYTES = 31_457_280L
        const val TIMEOUT_SECONDS = 60L
        val SCHEMES = setOf("http", "https")
        const val CHECK_CONTENT_TYPE = false
        const val REDIRECTS = "platform default"
    }
}
