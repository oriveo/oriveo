package ai.oriveo.community.core.voice

import io.ktor.client.HttpClient
import io.ktor.client.network.sockets.ConnectTimeoutException
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.expectSuccess
import io.ktor.client.request.forms.MultiPartFormDataContent
import io.ktor.client.request.forms.formData
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.Headers
import io.ktor.http.HttpHeaders
import io.ktor.http.content.TextContent
import io.ktor.http.isSuccess
import java.io.File
import java.net.SocketTimeoutException
import java.util.Base64
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.roundToLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/**
 * Cloud dictation: the slot's .aac is remuxed into a temporary m4a and uploaded; openai_transcriptions / xai_stt use multipart,
 * while gemini_transcribe / dashscope_asr base64-encode the m4a into a JSON body ([DictationRules.requestJson]).
 * When the entry's maxBytes / maxDurationSec is exceeded, the audio is split at silence points per [DictationRules.segmentPlan],
 * transcribed in turn, and joined in order with [DictationRules.join]; if any segment ultimately fails the whole run fails and later segments are not sent.
 * Each failed segment is automatically retried at most once per [DictationRules.failureDecision]. The temporary m4a lives in cacheDir and is deleted after use; the slot's .aac is left untouched.
 * Requests always use expectSuccess = false; the status code and Retry-After are handled here.
 */
class CloudSTTEngine(
    private val httpClient: HttpClient,
    private val entry: VoiceSttEntry,
    baseUrl: String,
    private val apiKey: String,
    private val cacheDir: File,
    private val sleeper: suspend (Long) -> Unit = { delay(it) },
) : STTEngine {
    /** An unbuildable address does not throw at construction; the transcribe entry point returns [DictationFailure.InvalidEndpoint] instead. */
    private val url: String? = DictationRules.requestUrl(baseUrl, entry)

    override val engineName: String = ENGINE_NAME

    override suspend fun transcribe(segment: STTSegment, language: String?): STTResult {
        val url = url ?: return STTResult.Failed(DictationFailure.InvalidEndpoint, DictationPrimaryAction.CheckConnection)
        val whole = export(segment, segment.range) ?: return exportFailed()
        val spans = plan(segment, whole.size.toLong())
        if (spans.size <= 1) return sendWithRetry(url, whole, language)

        val base = segment.range?.start ?: 0.0
        val texts = mutableListOf<String>()
        for (span in spans) {
            // Spans that round to zero length are not uploaded.
            if (span.endSec - span.startSec <= DictationRules.COMPARE_TOLERANCE) continue
            val bytes = export(segment, (base + span.startSec)..(base + span.endSec)) ?: return exportFailed()
            when (val result = sendWithRetry(url, bytes, language)) {
                is STTResult.Success -> texts += result.text
                is STTResult.Failed -> return result
            }
        }
        return STTResult.Success(DictationRules.join(texts))
    }

    /** Exports a recording time range to a temporary m4a and reads the bytes back, deleting the temp file right away; returns null if remuxing throws. */
    private suspend fun export(segment: STTSegment, range: ClosedFloatingPointRange<Double>?): ByteArray? =
        withContext(Dispatchers.IO) {
            cacheDir.mkdirs()
            val m4a = File.createTempFile(TEMP_PREFIX, TEMP_SUFFIX, cacheDir)
            try {
                RecordingExporter.toM4a(segment.aac, m4a, range, segment.primingFrames)
                m4a.readBytes()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            } finally {
                m4a.delete()
            }
        }

    /**
     * Segment plan (recording time relative to the range start). Duration = frames * 1024 / sampleRate - priming / sampleRate,
     * bitrate = whole-m4a bytes / duration; silence runs are computed from the sidecar envelope, shifted into the range, then handed to segmentPlan.
     */
    private suspend fun plan(segment: STTSegment, uploadBytes: Long): List<DictationSpan> {
        val stream = withContext(Dispatchers.IO) { AdtsFormat.parse(segment.aac.readBytes()) }
        val sampleRate = stream.sampleRate ?: return listOf(DictationSpan(0.0, 0.0))
        val recordingSec = (stream.frames.size.toLong() * AdtsStream.SAMPLES_PER_FRAME - segment.primingFrames)
            .toDouble() / sampleRate
        val base = segment.range?.start ?: 0.0
        val durationSec = segment.range?.let { it.endInclusive - it.start } ?: recordingSec
        val silences = DictationRules.silenceRuns(segment.envelope)
            .map { DictationSpan(it.startSec - base, it.endSec - base) }
            .filter { it.endSec > 0 && it.startSec < durationSec }
        return DictationRules.segmentPlan(entry, durationSec, uploadBytes, silences)
    }

    /** Request for one segment: retries are counted per segment, with at most one automatic retry each. */
    private suspend fun sendWithRetry(url: String, bytes: ByteArray, language: String?): STTResult {
        var attempt = 1
        while (true) {
            val failure = when (val outcome = send(url, bytes, language)) {
                is STTResult.Success -> return outcome
                is STTResult.Failed -> outcome.failure
            }
            val decision = DictationRules.failureDecision(failure, attempt)
            if (!decision.autoRetry) {
                return STTResult.Failed(
                    failure,
                    decision.primaryAction ?: DictationPrimaryAction.Retry,
                    autoRetried = attempt > 1,
                )
            }
            val delaySec = decision.delaySec ?: DictationRules.DEFAULT_RETRY_DELAY_SEC
            sleeper((delaySec * MILLIS_PER_SECOND).roundToLong())
            attempt++
        }
    }

    private fun exportFailed(): STTResult = STTResult.Failed(DictationFailure.ExportFailed, DictationPrimaryAction.Retry)

    /** Sends one request; on failure primaryAction is only a placeholder that the caller recomputes from the decision table. */
    private suspend fun send(url: String, bytes: ByteArray, language: String?): STTResult {
        // The JSON request body (including the whole audio as base64, up to 14.5 MB for gemini) is built off the main thread.
        val jsonBody = if (DictationRules.isJsonRequest(entry.transport)) {
            withContext(Dispatchers.Default) {
                DictationRules.requestJson(entry, language, Base64.getEncoder().encodeToString(bytes)).toString()
            }
        } else {
            null
        }
        val response: HttpResponse = try {
            httpClient.post(url) {
                expectSuccess = false
                val (name, value) = DictationRules.authorizationHeader(entry.transport, apiKey)
                header(name, value)
                // JSON requests send only the auth header and Content-Type on the wire; multipart still carries Accept.
                if (jsonBody != null) {
                    setBody(TextContent(jsonBody, ContentType.Application.Json))
                } else {
                    header(HttpHeaders.Accept, "application/json")
                    setBody(MultiPartFormDataContent(buildParts(bytes, language)))
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: HttpRequestTimeoutException) {
            return failed(DictationFailure.Timeout)
        } catch (_: ConnectTimeoutException) {
            return failed(DictationFailure.Timeout)
        } catch (_: SocketTimeoutException) {
            return failed(DictationFailure.Timeout)
        } catch (_: Exception) {
            return failed(DictationFailure.Network)
        }

        if (!response.status.isSuccess()) {
            return failed(DictationFailure.Http(response.status.value, response.headers[HttpHeaders.RetryAfter]))
        }
        val body = try {
            response.bodyAsText()
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return failed(DictationFailure.Network)
        }
        // JSON parsing and transcript extraction stay off the main thread.
        val text = withContext(Dispatchers.Default) {
            val element = runCatching { Json.parseToJsonElement(body) }.getOrNull()
            DictationRules.transcript(entry.transport, element)
        } ?: return failed(DictationFailure.InvalidResponse)
        return STTResult.Success(text)
    }

    private fun failed(failure: DictationFailure): STTResult =
        STTResult.Failed(failure, DictationPrimaryAction.Retry)

    /** Part order follows [DictationRules.requestParts]: model, language hint, file. */
    private fun buildParts(bytes: ByteArray, language: String?) = formData {
        for (part in DictationRules.requestParts(entry, language)) {
            when (part) {
                is DictationRequestPart.Field -> append(part.name, part.value)
                is DictationRequestPart.File -> append(
                    key = part.name,
                    value = bytes,
                    headers = Headers.build {
                        append(HttpHeaders.ContentType, part.contentType)
                        append(HttpHeaders.ContentDisposition, "filename=\"${part.filename}\"")
                    },
                )
            }
        }
    }

    companion object {
        const val ENGINE_NAME = "cloud"
        private const val TEMP_PREFIX = "dictation-"
        private const val TEMP_SUFFIX = ".m4a"
        private const val MILLIS_PER_SECOND = 1000.0
    }
}
