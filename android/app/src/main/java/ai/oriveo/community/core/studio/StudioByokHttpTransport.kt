package ai.oriveo.community.core.studio

import java.net.ConnectException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import okhttp3.Call
import okhttp3.Headers
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.ResponseBody
import okio.Buffer

/**
 * Production BYOK transport: turns an [ImageHttpRequest] into an OkHttp call through [StudioHttpTransport]
 * (call-level total timeout), runs it on the IO dispatcher and cancels the call when the coroutine is
 * cancelled. URL images are downloaded with [StudioImageFetcher].
 */
class StudioByokHttpTransport(
    private val http: StudioHttpTransport,
    private val fetcher: StudioImageFetcher,
) : StudioByokTransport {
    /**
     * Any HTTP status comes back as a response with the raw body bytes; transport and body-read errors come back
     * as a failure. Coroutine cancellation cancels the call and rethrows. [callCanceled] is true only when this
     * coroutine cancelled the call: OkHttp also marks a call canceled when its call timeout fires, and that
     * must stay a timeout. Failures before anything leaves the device (request not buildable, Studio compiled
     * out) come back as a [ConnectException] with the original error as cause, so they classify as pre_connect.
     */
    override suspend fun send(request: ImageHttpRequest, timeoutSeconds: Int, maxBodyBytes: Long): StudioByokTransport.SendOutcome {
        val okRequest = try {
            toOkHttpRequest(request)
        } catch (e: IllegalArgumentException) {
            return notSent(e)
        }
        val call = http.newCall(okRequest, timeoutSeconds) ?: return notSent(IllegalStateException("Studio is compiled out"))
        val canceledByCoroutine = AtomicBoolean(false)
        return coroutineScope {
            val running = async(Dispatchers.IO) { execute(call, maxBodyBytes, canceledByCoroutine) }
            try {
                running.await()
            } catch (e: CancellationException) {
                canceledByCoroutine.set(true)
                call.cancel()
                throw e
            }
        }
    }

    override suspend fun fetchImage(url: String): StudioImageResponse.Outcome = fetcher.fetch(url)

    /** Blocking; runs on the IO dispatcher. The call timeout and cancel both interrupt the body read. */
    private fun execute(call: Call, maxBodyBytes: Long, canceledByCoroutine: AtomicBoolean): StudioByokTransport.SendOutcome = try {
        call.execute().use { StudioByokTransport.SendOutcome.Response(it.code, readCapped(it.body, maxBodyBytes)) }
    } catch (e: Exception) {
        StudioByokTransport.SendOutcome.Failure(e, callCanceled = canceledByCoroutine.get())
    }

    private fun notSent(cause: Exception): StudioByokTransport.SendOutcome =
        StudioByokTransport.SendOutcome.Failure(ConnectException("request not sent: ${cause.message}").apply { initCause(cause) }, callCanceled = false)

    companion object {
        private val JSON_MEDIA_TYPE = "application/json".toMediaType()
        private const val CONTENT_TYPE = "Content-Type"
        private const val READ_CHUNK = 8_192L

        /** Reads the body until EOF or [maxBodyBytes] + 1 bytes, whichever comes first; never more. */
        fun readCapped(body: ResponseBody, maxBodyBytes: Long): ByteArray {
            val cap = maxBodyBytes.coerceAtLeast(0) + 1
            val source = body.source()
            val buffer = Buffer()
            while (buffer.size < cap) {
                if (source.read(buffer, minOf(READ_CHUNK, cap - buffer.size)) == -1L) break
            }
            return buffer.readByteArray()
        }

        /**
         * JSON bodies go as application/json; multipart bodies are encoded by OkHttp (text fields, files with
         * filename and mime), so the request's own multipart Content-Type is dropped to keep OkHttp's boundary.
         * Other headers are copied in order.
         */
        fun toOkHttpRequest(request: ImageHttpRequest): Request {
            val multipart = request.body is ImageRequestBody.Multipart
            val body: RequestBody = when (val source = request.body) {
                is ImageRequestBody.Json -> source.json.toString().toByteArray(Charsets.UTF_8).toRequestBody(JSON_MEDIA_TYPE)
                is ImageRequestBody.Multipart -> MultipartBody.Builder().setType(MultipartBody.FORM).apply {
                    source.fields.forEach { (name, value) -> addFormDataPart(name, value) }
                    source.files.forEach { file ->
                        addFormDataPart(file.name, file.filename, file.data.toRequestBody(file.mime.toMediaTypeOrNull()))
                    }
                }.build()
            }
            val headers = Headers.Builder().apply {
                request.headers.forEach { (name, value) ->
                    if (!(multipart && name.equals(CONTENT_TYPE, ignoreCase = true))) add(name, value)
                }
            }.build()
            return Request.Builder().url(request.url).headers(headers).method(request.method, body).build()
        }
    }
}
