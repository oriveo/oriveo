package ai.oriveo.community.core.data.repository.streaming


internal class StreamingTokenBuffer(initialText: String, initialReasoning: String = "") {
    private val buffer = StringBuilder()
    private val accumulated = StringBuilder(initialText)
    private val accumulatedReasoning = StringBuilder(initialReasoning)
    private val reasoningBuffer = StringBuilder()

    private var lastFlushTime = System.currentTimeMillis()
    private var lastReasoningFlushTime = System.currentTimeMillis()
    private var lastPartialFlushTime = System.currentTimeMillis()
    private var lastPartialFlushLength = 0

    val accumulatedText: String get() = accumulated.toString()
    val accumulatedReasoningText: String get() = accumulatedReasoning.toString()
    val accumulatedTextLength: Int get() = accumulated.length

    
    fun appendDelta(text: String, now: Long): Boolean {
        buffer.append(text)
        val containsNewline = text.contains("\n")
        return buffer.length >= FLUSH_CHAR_THRESHOLD ||
            containsNewline ||
            (now - lastFlushTime) >= FLUSH_INTERVAL_MS
    }

    
    fun drainTextToAccumulated(now: Long) {
        
        
        
        
        if (accumulated.isEmpty()) {
            var start = 0
            while (start < buffer.length && buffer[start].isWhitespace()) start++
            if (start > 0) buffer.delete(0, start)
        }
        accumulated.append(buffer)
        buffer.clear()
        lastFlushTime = now
    }

    
    fun appendReasoning(text: String, now: Long): Boolean {
        accumulatedReasoning.append(text)
        reasoningBuffer.append(text)
        val containsNewline = text.contains("\n")
        return reasoningBuffer.length >= FLUSH_CHAR_THRESHOLD ||
            containsNewline ||
            (now - lastReasoningFlushTime) >= FLUSH_INTERVAL_MS
    }

    
    fun markReasoningFlushed(now: Long) {
        reasoningBuffer.clear()
        lastReasoningFlushTime = now
    }

    
    fun hasPendingText(): Boolean = buffer.isNotEmpty()

    
    fun hasPendingReasoning(): Boolean = reasoningBuffer.isNotEmpty()

    
    fun shouldPartialFlush(now: Long, charThreshold: Int, timeThresholdMs: Long): Boolean {
        val accumLen = accumulated.length
        return accumLen - lastPartialFlushLength >= charThreshold ||
            (now - lastPartialFlushTime) >= timeThresholdMs
    }

    fun markPartialFlushed(now: Long) {
        lastPartialFlushTime = now
        lastPartialFlushLength = accumulated.length
    }

    
    fun clear() {
        buffer.clear()
    }

    companion object {
        
        const val FLUSH_CHAR_THRESHOLD = 32

        
        const val FLUSH_INTERVAL_MS = 40L
    }
}
