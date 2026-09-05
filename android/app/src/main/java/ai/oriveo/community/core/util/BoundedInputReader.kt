package ai.oriveo.community.core.util

import java.io.IOException
import java.io.InputStream

class InputSizeLimitExceededException(
    val maxBytes: Long,
) : IOException("Input exceeds the $maxBytes byte limit")


const val UNKNOWN_INPUT_SIZE = -1L


@Throws(InputSizeLimitExceededException::class)
fun InputStream.readBytesLimited(
    maxBytes: Long,
    expectedBytes: Long = UNKNOWN_INPUT_SIZE,
): ByteArray {
    require(maxBytes in 0..Int.MAX_VALUE.toLong()) { "maxBytes must fit in a ByteArray" }

    val max = maxBytes.toInt()
    val initialCapacity = if (expectedBytes in 0..maxBytes) {
        expectedBytes.toInt()
    } else {
        minOf(max, DEFAULT_BUFFER_SIZE)
    }

    var buffer = ByteArray(initialCapacity)
    var size = 0

    while (true) {
        if (size == buffer.size) {
            if (size >= max) {
                
                if (read() >= 0) throw InputSizeLimitExceededException(maxBytes)
                return buffer
            }
            buffer = buffer.copyOf(grownCapacity(buffer.size, max))
        }
        val read = read(buffer, size, buffer.size - size)
        if (read < 0) break
        if (read == 0) {
            
            val singleByte = read()
            if (singleByte < 0) break
            buffer[size++] = singleByte.toByte()
            continue
        }
        size += read
    }

    return if (size == buffer.size) buffer else buffer.copyOf(size)
}

private fun grownCapacity(current: Int, max: Int): Int {
    val doubled = if (current == 0) DEFAULT_BUFFER_SIZE.toLong() else current.toLong() * 2
    return doubled.coerceAtMost(max.toLong()).toInt()
}
