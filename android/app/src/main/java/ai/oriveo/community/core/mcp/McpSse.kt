package ai.oriveo.community.core.mcp

import java.io.ByteArrayOutputStream
import kotlinx.serialization.json.JsonElement

/**
 * Incremental SSE (`text/event-stream`) parser: feed it bytes and it emits each event's JSON payload as soon as
 * the event is complete.
 *
 * It has to be incremental: after the final response a server SHOULD close the stream but is not guaranteed to.
 * Parsing only once the stream closes would leave a write-type tool that has already run waiting for the full
 * timeout and then reported as failed.
 *
 * Line endings follow the SSE specification: LF, CRLF and a lone CR. A leading BOM is dropped; multiple `data:`
 * lines of one event are joined with `\n`; `event:` / `id:` / `retry:` and comment lines starting with `:` are
 * ignored. A payload that is not valid JSON is skipped (one bad frame must not kill the whole stream);
 * invalid UTF-8 is replaced with U+FFFD in place rather than discarding the payload. Resuming with
 * `Last-Event-ID` is not supported, so event ids are not kept.
 *
 * Matches iOS `McpSSEParser` rule for rule.
 */
class McpSseParser {
    private val line = ByteArrayOutputStream()
    private val dataLines = mutableListOf<String>()

    /** The previous byte was CR: an LF right after it belongs to the same line ending and is swallowed. */
    private var previousWasCR = false

    /** Still at the very start of the stream (used to detect the BOM). */
    private var atStreamStart = true

    /** This event's payload was already emitted early when its `data:` line ended, so the blank line must not emit it again. */
    private var emittedEarly = false

    /** Feeds one byte; returns the event's JSON payload when an event completes. */
    fun consume(byte: Byte): JsonElement? = when (byte) {
        LF -> if (previousWasCR) {
            previousWasCR = false
            null
        } else {
            endLine()
        }
        CR -> {
            previousWasCR = true
            endLine()
        }
        else -> {
            previousWasCR = false
            line.write(byte.toInt())
            null
        }
    }

    /**
     * End of stream: also emit a last event that was not terminated by a blank line.
     *
     * The specification says an unterminated event should be discarded, but here "the response arrived in full
     * and only the blank line is missing" would turn a call that already ran into a failure, so it is accepted.
     */
    fun finish(): JsonElement? {
        var result: JsonElement? = null
        if (line.size() > 0) result = endLine()
        return dispatch() ?: result
    }

    private fun endLine(): JsonElement? {
        var bytes = line.toByteArray()
        line.reset()
        if (atStreamStart) {
            atStreamStart = false
            if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) {
                bytes = bytes.copyOfRange(3, bytes.size)
            }
        }
        if (bytes.isEmpty()) return dispatch()
        // A line starting with a colon is a comment.
        if (bytes[0] == COLON) return null

        val colon = bytes.indexOf(COLON)
        val field: ByteArray
        var valueStart: Int
        if (colon >= 0) {
            field = bytes.copyOfRange(0, colon)
            valueStart = colon + 1
            // Specification: when the value starts with a leading space, strip it (one only).
            if (valueStart < bytes.size && bytes[valueStart] == SPACE) valueStart += 1
        } else {
            // No colon: the whole line is the field name and the value is empty.
            field = bytes
            valueStart = bytes.size
        }
        if (!field.contentEquals(DATA_FIELD)) return null

        // Invalid UTF-8 is replaced with U+FFFD in place (the default behavior of `String(bytes, UTF_8)`).
        dataLines += String(bytes, valueStart, bytes.size - valueStart, Charsets.UTF_8)
        // Nearly every server sends a single data line per event. When that line is complete JSON on its own, emit
        // it right away instead of waiting for the blank line:
        // some servers stop sending bytes altogether after the last data line.
        // Only the first line is tried: re-parsing on every line of a multi-line event is quadratic, and a peer
        // could use that to stall the client.
        if (dataLines.size == 1) {
            val value = McpJson.parseOrNull(dataLines[0])
            if (value != null) {
                emittedEarly = true
                return value
            }
        }
        return null
    }

    private fun dispatch(): JsonElement? {
        try {
            if (dataLines.isEmpty()) return null
            // A single-line event that was emitted early is not emitted again; if more data lines followed
            // (a multi-line event), the joined whole is parsed afresh.
            if (emittedEarly && dataLines.size == 1) return null
            return McpJson.parseOrNull(dataLines.joinToString("\n"))
        } finally {
            dataLines.clear()
            emittedEarly = false
        }
    }

    private companion object {
        const val LF: Byte = 0x0A
        const val CR: Byte = 0x0D
        const val COLON: Byte = 0x3A
        const val SPACE: Byte = 0x20
        val DATA_FIELD = "data".toByteArray(Charsets.UTF_8)
    }
}

object McpSse {
    /**
     * Parses a whole chunk of SSE bytes into JSON-RPC messages in order of appearance. It uses the same parser as
     * the streaming read
     * and exists only as a fallback for a dishonest `Content-Type` and for tests.
     */
    fun messages(data: ByteArray): List<JsonElement> {
        val parser = McpSseParser()
        val messages = mutableListOf<JsonElement>()
        for (byte in data) parser.consume(byte)?.let(messages::add)
        parser.finish()?.let(messages::add)
        return messages
    }
}
