package ai.oriveo.community.ui.component.markdown

import java.security.MessageDigest
import java.util.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Large-input regression: `splitClosedAndOpenLatex`'s fence scan runs a hand-written state
 * machine instead of `substring` plus a freshly compiled `Regex` per newline, since streamed
 * text would otherwise recompile a pattern on every line. This is a behavior-sensitive hot
 * path, so this test pins a digest of the output over a fixed corpus to catch any
 * byte-for-byte drift.
 */
class LatexNormalizerLargeInputTest {

    // Digest (SHA-256) of the output over this corpus. Must stay exactly the same.
    private val expectedCorpusDigest = "9cc6e69b794736072455d66a51f4e43a09cad7c62c7a5279646633db1a3a3c79"

    @Test
    fun `splitting a large corpus produces a stable digest`() {
        val digest = MessageDigest.getInstance("SHA-256")
        buildCorpus().forEach { doc ->
            val r = splitClosedAndOpenLatex(doc)
            digest.update(r.closed.toByteArray(Charsets.UTF_8))
            digest.update(0)
            digest.update(r.tail.toByteArray(Charsets.UTF_8))
            digest.update(1)
            digest.update(normalizeLatexDelimiters(r.closed).toByteArray(Charsets.UTF_8))
            digest.update(2)
        }
        assertEquals(expectedCorpusDigest, digest.digest().joinToString("") { "%02x".format(it) })
    }

    @Test
    fun `five hundred line multi-fence document is unaffected by line count`() {
        val doc = buildString {
            repeat(100) { block ->
                append("## Section $block\n")
                append("inline \\(a_$block + b\\) mixed with `code$block`.\n")
                append("```kotlin\nval x = \"\\(not math\\)\"\n```\n")
                append("\\[\nS_$block = \\sum_{i=0}^{n} i\n\\]\n")
            }
            append("trailing unclosed \\(z + ")
        }
        assertTrue(doc.lines().size >= 500)
        val r = splitClosedAndOpenLatex(doc)
        assertEquals("\\(z + ", r.tail)
        assertEquals(doc.length - r.tail.length, r.closed.length)
        assertEquals(doc, r.closed + r.tail)
    }

    /** Deterministic corpus: a seeded Random assembles markdown fragments, covering fences, indentation, line endings, and every kind of delimiter. */
    private fun buildCorpus(): List<String> {
        val random = Random(20260826L)
        val fragments = listOf(
            "plain text line\n",
            "inline \\(x + y\\) end\n",
            "unclosed \\(x + y\n",
            "block \\[\nx^2\n\\]\n",
            "unclosed block \\[\nx^2\n",
            "\$\$a + b\$\$\n",
            "\$\$a + b\n",
            "price \$40 and \$5.99\n",
            "inline formula \$x\$ end\n",
            "open \$x + \n",
            "bar\$x unclosed\n",
            "`inline \\(code\\)` trailing\n",
            "``double backtick ` embedded`` trailing\n",
            "```\nfenced \\(a\\)\n```\n",
            "  ```\ntwo-space indented fence\n  ```\n",
            "   ~~~\nthree-space tilde fence \\[x\\]\n   ~~~\n",
            "    ```\nfour-space is not a fence \\(x\\)\n    ```\n",
            "`````\nfive-backtick fence\n`````\n",
            "~~~~\nfour-tilde fence\n~~~\nstill inside fence\n~~~~\n",
            "```\nunclosed fence \\(x\n",
            "```js\nconst s = '```';\n```\n",
            "CRLF line\r\n",
            "```\r\nCRLF fence\r\n```\r\n",
            "escaped \\\$ is not an opener\n",
            "\\(a\\) \\[b\\] \$\$c\$\$ \$d\$ all closed\n",
            "table | \$x\$ | \\(y\\) |\n",
            "```\n",
            "~~~\n",
            "\n",
            "trailing whitespace fence\n```   \ncontent\n```   \n",
        )
        return (0 until 220).map { docIndex ->
            val pieces = 1 + random.nextInt(14)
            buildString {
                repeat(pieces) { append(fragments[random.nextInt(fragments.size)]) }
                if (docIndex % 7 == 0) append(fragments[random.nextInt(fragments.size)].trimEnd())
            }
        }
    }
}
