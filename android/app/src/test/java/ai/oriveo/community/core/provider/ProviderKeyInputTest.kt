package ai.oriveo.community.core.provider

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Character validation for API key entry. Pins the behaviour that rejects a paste which
 * dragged illegal characters in with it; the accepted set is exactly the printable ASCII
 * range.
 */
class ProviderKeyInputTest {

    @Test
    fun `accepts common provider keys`() {
        assertTrue(ProviderKeyInput.isPrintableAsciiKey("sk-1234567890ABCDEFabcdef"))
        assertTrue(ProviderKeyInput.isPrintableAsciiKey("sk-ant-api03-AaBbCc1234"))
        assertTrue(ProviderKeyInput.isPrintableAsciiKey("AIzaSy0123-_AAAA1234"))
        assertTrue(
            ProviderKeyInput.isPrintableAsciiKey(
                "yls-64164880eb21a6377e77349ae9ecd5b0fc6200ef0a3d0c8120260413",
            ),
        )
    }

    @Test
    fun `rejects empty`() {
        assertFalse(ProviderKeyInput.isPrintableAsciiKey(""))
    }

    @Test
    fun `rejects newline and pasted terminal junk`() {
        // Real-world case: copying a whole block out of a terminal drags the trailing
        // newline and the text after the key along with it.
        assertFalse(
            ProviderKeyInput.isPrintableAsciiKey(
                "yls-64164880eb21a6377e77349ae9ecd5b0fc6200ef0a3d0c8120260413\nthat is the final list.",
            ),
        )
        assertFalse(ProviderKeyInput.isPrintableAsciiKey("sk-test\nabc"))
        assertFalse(ProviderKeyInput.isPrintableAsciiKey("sk-test\tabc"))
        assertFalse(ProviderKeyInput.isPrintableAsciiKey("sk-test\r\nabc"))
    }

    @Test
    fun `rejects non-ascii chars`() {
        assertFalse(ProviderKeyInput.isPrintableAsciiKey("sk-clékey"))
        assertFalse(ProviderKeyInput.isPrintableAsciiKey("sk-test abc")) // non-breaking space
        assertFalse(ProviderKeyInput.isPrintableAsciiKey("sk-test​abc")) // zero-width space
        assertFalse(ProviderKeyInput.isPrintableAsciiKey("﻿sk-test")) // BOM
    }

    @Test
    fun `accepts inner half-width space`() {
        // A half-width space is printable ASCII; trimming leading and trailing whitespace is
        // each entry point's own job.
        assertTrue(ProviderKeyInput.isPrintableAsciiKey("sk a"))
    }
}
