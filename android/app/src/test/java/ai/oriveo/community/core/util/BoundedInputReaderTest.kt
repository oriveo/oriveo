package ai.oriveo.community.core.util

import java.io.ByteArrayInputStream
import java.io.InputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class BoundedInputReaderTest {

    @Test
    fun `reads input exactly at the limit`() {
        val input = byteArrayOf(1, 2, 3, 4)

        assertArrayEquals(input, ByteArrayInputStream(input).readBytesLimited(4))
    }

    @Test
    fun `rejects input before retaining bytes beyond the limit`() {
        val error = runCatching {
            ByteArrayInputStream(ByteArray(8)).readBytesLimited(7)
        }.exceptionOrNull()

        assertEquals(7L, (error as InputSizeLimitExceededException).maxBytes)
    }

    @Test
    fun `zero limit accepts empty input`() {
        assertArrayEquals(byteArrayOf(), ByteArrayInputStream(byteArrayOf()).readBytesLimited(0))
    }

    @Test
    fun `exact size hint reads the whole stream`() {
        val input = ByteArray(64_000) { (it % 251).toByte() }

        val read = ByteArrayInputStream(input).readBytesLimited(
            maxBytes = 25L * 1024 * 1024,
            expectedBytes = input.size.toLong(),
        )

        assertArrayEquals(input, read)
    }

    @Test
    fun `size hint smaller than the stream still reads everything`() {
        val input = ByteArray(20_000) { (it % 97).toByte() }

        val read = ByteArrayInputStream(input).readBytesLimited(
            maxBytes = 1024L * 1024,
            expectedBytes = 10L,
        )

        assertArrayEquals(input, read)
    }

    @Test
    fun `size hint larger than the stream trims the result`() {
        val input = byteArrayOf(9, 8, 7)

        val read = ByteArrayInputStream(input).readBytesLimited(
            maxBytes = 1024L,
            expectedBytes = 1024L,
        )

        assertArrayEquals(input, read)
    }

    @Test
    fun `size hint beyond the limit is ignored and the limit still holds`() {
        val error = runCatching {
            ByteArrayInputStream(ByteArray(8)).readBytesLimited(
                maxBytes = 7,
                expectedBytes = 4096,
            )
        }.exceptionOrNull()

        assertEquals(7L, (error as InputSizeLimitExceededException).maxBytes)
    }

    @Test
    fun `stream returning zero before data does not spin forever`() {
        val input = byteArrayOf(1, 2, 3)

        assertArrayEquals(input, StallingStream(input).readBytesLimited(1024))
    }

    
    private class StallingStream(private val data: ByteArray) : InputStream() {
        private var position = 0
        private var stalled = false

        override fun read(): Int =
            if (position < data.size) data[position++].toInt() and 0xFF else -1

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (!stalled) {
                stalled = true
                return 0
            }
            if (position >= data.size) return -1
            val count = minOf(len, data.size - position)
            System.arraycopy(data, position, b, off, count)
            position += count
            return count
        }
    }
}
