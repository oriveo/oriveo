package ai.oriveo.community.core.provider

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.InputStream
import kotlinx.serialization.json.Json

/** One dispatched SSE event. */
data class SseFrame(
    /** Event name; null when the event carried no `event` field, or an empty one. */
    val event: String?,
    /** The data lines joined with LF, never trimmed. */
    val data: String,
    /** The data lines before joining. */
    val dataLines: List<String>,
    /** Parallel to [dataLines]: the event name in effect when that data line arrived, used when lines are delivered one by one. */
    val dataLineEvents: List<String?>,
    /** The last id seen up to this event; null before the first. */
    val id: String?,
    /** The retry value of this event in milliseconds; null when it carried none. */
    val retry: Long?,
)

/** What the decoder hands out, in order of appearance: a dispatched event, or a line that takes no part in assembling one. */
sealed interface SseItem {
    data class Frame(val frame: SseFrame) : SseItem

    /** A comment, `id` / `retry`, an unknown field, or a blank line that dispatched nothing (`raw` is empty); `raw` is the line as it arrived. */
    data class Line(val raw: String) : SseItem
}

/**
 * SSE framing decoder following the WHATWG EventSource parsing algorithm:
 *   - a line ends with CRLF, a lone LF or a lone CR; a CRLF cut across two chunks is still one line end
 *   - a byte order mark at the start of the stream is dropped once, later ones are data
 *   - a line that starts with a colon is a comment; the first colon separates field name and value,
 *     and only the single space right after it is removed from the value (no trimming)
 *   - the data lines of one event are joined with LF; a blank line dispatches the event, and an event
 *     without a data line is not dispatched
 *
 * One deliberate difference from the specification, because upstreams routinely close the connection
 * right after `data: [DONE]`: when the stream ends without a line end or without the final blank
 * line, [finish] still counts the last line and dispatches the pending event, where the specification
 * discards both.
 *
 * The end sentinel (`[DONE]`) is an ordinary event at this level; the protocol above gives it meaning.
 * Lines are split on bytes and decoded whole, so a multi-byte character cut between two chunks is
 * unaffected; invalid UTF-8 is replaced with U+FFFD where it occurs.
 */
class SseFrameDecoder {
    /** Number of comment lines seen so far. */
    var comments: Int = 0
        private set

    private val line = ByteArrayOutputStream()

    /** The previous byte was CR: an LF right after it belongs to the same line end and is swallowed. */
    private var previousWasCR = false
    private var atStreamStart = true
    private val dataLines = mutableListOf<String>()
    private val dataLineEvents = mutableListOf<String?>()
    private var eventName = ""
    private var lastId: String? = null
    private var retry: Long? = null

    /** Feeds bytes; whatever they complete goes to [sink] in order of appearance. */
    fun push(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size - offset, sink: (SseItem) -> Unit) {
        for (index in offset until offset + length) {
            when (val byte = bytes[index]) {
                LF -> if (previousWasCR) previousWasCR = false else endLine(sink)
                CR -> {
                    previousWasCR = true
                    endLine(sink)
                }
                else -> {
                    previousWasCR = false
                    line.write(byte.toInt())
                }
            }
        }
    }

    /** End of stream: the last line counts even without a line end, and a pending event is dispatched. */
    fun finish(sink: (SseItem) -> Unit) {
        if (line.size() > 0) endLine(sink)
        dispatch()?.let { sink(SseItem.Frame(it)) }
    }

    private fun endLine(sink: (SseItem) -> Unit) {
        var bytes = line.toByteArray()
        line.reset()
        if (atStreamStart) {
            atStreamStart = false
            if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) {
                bytes = bytes.copyOfRange(3, bytes.size)
            }
        }
        if (bytes.isEmpty()) {
            sink(dispatch()?.let { SseItem.Frame(it) } ?: SseItem.Line(""))
            return
        }
        val text = String(bytes, Charsets.UTF_8)
        val colon = text.indexOf(':')
        if (colon == 0) {
            comments += 1
            sink(SseItem.Line(text))
            return
        }
        val field = if (colon < 0) text else text.substring(0, colon)
        var value = if (colon < 0) "" else text.substring(colon + 1)
        if (value.startsWith(' ')) value = value.substring(1)

        when (field) {
            "data" -> {
                dataLines += value
                dataLineEvents += eventName.ifEmpty { null }
            }
            "event" -> eventName = value
            else -> {
                if (field == "id" && !value.contains('\u0000')) lastId = value
                if (field == "retry" && value.isNotEmpty() && value.all { it in '0'..'9' }) retry = value.toLongOrNull()
                sink(SseItem.Line(text))
            }
        }
    }

    private fun dispatch(): SseFrame? {
        val lines = dataLines.toList()
        val lineEvents = dataLineEvents.toList()
        val event = eventName
        val eventRetry = retry
        dataLines.clear()
        dataLineEvents.clear()
        eventName = ""
        retry = null
        if (lines.isEmpty()) return null
        return SseFrame(
            event = event.ifEmpty { null },
            data = lines.joinToString("\n"),
            dataLines = lines,
            dataLineEvents = lineEvents,
            id = lastId,
            retry = eventRetry,
        )
    }

    private companion object {
        const val LF: Byte = 0x0A
        const val CR: Byte = 0x0D
    }
}

/**
 * Reads an upstream response body as SSE lines, one per call, for the line loops of each protocol.
 * The interface is that of `BufferedReader.readLine()`, and framing is left to [SseFrameDecoder], so
 * every loop receives lines that are already in canonical form:
 *   - an event becomes `event: <name>` (when it has one), `data: <the joined data>` and a blank line
 *   - an event with empty data leaves only that blank line, since there is no payload to deliver
 *   - comments, `id` / `retry` and unknown field lines pass through as they arrived, so when the body
 *     is not SSE at all (JSON lines, an error body) the caller sees what reading by line would give
 *
 * Some upstreams separate several JSON messages with a single line break and no blank line between
 * events, so the data joined per the specification is not valid JSON. Each data line is then
 * delivered on its own, with the event name that was in effect when it arrived, so that "every data
 * line is a message" keeps working.
 */
class SseLineReader(private val input: InputStream) : Closeable {
    private val decoder = SseFrameDecoder()
    private val pending = ArrayDeque<String>()
    private val buffer = ByteArray(8 * 1024)
    private var finished = false

    /** The next line, or null at the end of the stream. Blocking IO: the caller moves it to the IO dispatcher. */
    fun readLine(): String? {
        while (pending.isEmpty()) {
            if (finished) return null
            val read = input.read(buffer)
            if (read < 0) {
                finished = true
                decoder.finish(::enqueue)
            } else {
                decoder.push(buffer, 0, read, ::enqueue)
            }
        }
        return pending.removeFirst()
    }

    override fun close() = input.close()

    private fun enqueue(item: SseItem) {
        pending += canonicalLines(item)
    }

    companion object {
        /** The canonical lines for one decoded item. */
        fun canonicalLines(item: SseItem): List<String> = when (item) {
            is SseItem.Line -> listOf(item.raw)
            is SseItem.Frame -> buildList {
                val frame = item.frame
                if (frame.data.isNotEmpty()) {
                    if (frame.dataLines.size > 1 && !isJson(frame.data)) {
                        frame.dataLines.forEachIndexed { index, line ->
                            if (line.isEmpty()) return@forEachIndexed
                            frame.dataLineEvents[index]?.let { add("event: $it") }
                            add("data: $line")
                        }
                    } else {
                        frame.event?.let { add("event: $it") }
                        add("data: ${frame.data}")
                    }
                }
                add("")
            }
        }

        private fun isJson(text: String): Boolean =
            runCatching { Json.parseToJsonElement(text) }.isSuccess
    }
}

/** See [SseLineReader]. */
fun InputStream.sseLineReader(): SseLineReader = SseLineReader(this)
