package ai.oriveo.community.core.provider

internal class ThinkingTagParser {
    sealed class Segment {
        data class Text(val value: String) : Segment()
        data class Reasoning(val value: String) : Segment()
    }

    private enum class Mode { Normal, Thinking }

    private var mode = Mode.Normal
    private var pending = ""
    private var fenceBackticks = 0
    private var inCodeFence = false

    fun parse(input: String, final: Boolean = false): List<Segment> {
        if (input.isEmpty() && !final) return emptyList()

        val current = pending + input
        pending = ""

        val events = mutableListOf<Segment>()
        var index = 0
        val out = StringBuilder()

        fun flush() {
            if (out.isEmpty()) return
            val value = out.toString()
            if (mode == Mode.Thinking) {
                events += Segment.Reasoning(value)
            } else {
                events += Segment.Text(value)
            }
            out.clear()
        }

        while (index < current.length) {
            if (mode == Mode.Normal) updateFenceState(current[index])

            if (!inCodeFence && current.startsWith(OPEN_TAG, index)) {
                flush()
                mode = Mode.Thinking
                index += OPEN_TAG.length
                continue
            }

            if (!inCodeFence && current.startsWith(CLOSE_TAG, index)) {
                flush()
                mode = Mode.Normal
                index += CLOSE_TAG.length
                continue
            }

            if (!final && isPossibleTagPrefix(current.substring(index))) {
                break
            }

            out.append(current[index])
            index += 1
        }

        pending = current.substring(index)
        if (final && pending.isNotEmpty()) {
            out.append(pending)
            pending = ""
        }
        flush()

        return events
    }

    private fun updateFenceState(char: Char) {
        if (char == '`') {
            fenceBackticks += 1
            if (fenceBackticks == 3) {
                inCodeFence = !inCodeFence
                fenceBackticks = 0
            }
            return
        }
        fenceBackticks = 0
    }

    private fun isPossibleTagPrefix(value: String): Boolean {
        val capped = value.take(MAX_TAG_LENGTH)
        return capped.length < MAX_TAG_LENGTH &&
            (OPEN_TAG.startsWith(capped) || CLOSE_TAG.startsWith(capped))
    }

    private companion object {
        const val OPEN_TAG = "<think>"
        const val CLOSE_TAG = "</think>"
        const val MAX_TAG_LENGTH = CLOSE_TAG.length
    }
}
