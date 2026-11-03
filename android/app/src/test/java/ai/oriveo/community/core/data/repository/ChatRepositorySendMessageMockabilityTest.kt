package ai.oriveo.community.core.data.repository

import ai.oriveo.community.core.model.Conversation
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.streaming.ConversationStreamingOutputs
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression guard: ChatRepository.sendMessage is a large coroutine state machine. Once its bytecode nears the
 * JVM 64KB per-method limit, MockK's inline instrumentation can no longer rewrite the class and every
 * `coEvery { chatRepository.sendMessage(...) }` in the view model tests runs the real body instead
 * (NPE on Provider.displayName for the matcher placeholder).
 */
class ChatRepositorySendMessageMockabilityTest {

    @Test
    fun `mockk intercepts sendMessage when stubbing with matchers`() = runTest {
        val repository = mockk<ChatRepository>()
        coEvery {
            repository.sendMessage(
                conversation = any(),
                text = any(),
                provider = any(),
                modelID = any(),
                existingMessages = any(),
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = any(),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
            )
        } returns Unit

        repository.sendMessage(
            conversation = Conversation(
                id = "conversation-1",
                title = "Title",
                providerID = "provider-1",
                providerKind = ProviderKind.OpenAI,
                modelID = "gpt-4o-mini",
            ),
            text = "hello",
            provider = Provider(id = "provider-1", kind = ProviderKind.OpenAI),
            modelID = "gpt-4o-mini",
            existingMessages = emptyList(),
            outputs = ConversationStreamingOutputs(
                streamingText = MutableStateFlow(""),
                streamingMessageId = MutableStateFlow(null),
            ),
        )

        coVerify(exactly = 1) {
            repository.sendMessage(
                conversation = any(),
                text = "hello",
                provider = any(),
                modelID = "gpt-4o-mini",
                existingMessages = any(),
                attachments = any(),
                reasoningMode = any(),
                webSearchEnabled = any(),
                requestOptions = any(),
                outputs = any(),
                persistUserMessage = any(),
                userMessageAlreadyInHistory = any(),
                appendToAssistant = any(),
            )
        }
    }

    @Test
    fun `sendMessage bytecode stays under the mockk instrumentation budget`() {
        val bytes = requireNotNull(ChatRepository::class.java.getResourceAsStream("ChatRepository.class")) {
            "ChatRepository.class is not on the test classpath"
        }.use { it.readBytes() }
        val lengths = methodCodeLengths(bytes, "sendMessage")
        assertEquals("expected exactly one sendMessage method body, got $lengths", 1, lengths.size)
        val codeLength = lengths.single()
        println("ChatRepository.sendMessage code length = $codeLength bytes (budget $SEND_MESSAGE_CODE_BUDGET)")
        assertTrue(
            "ChatRepository.sendMessage is $codeLength bytes of bytecode, over the $SEND_MESSAGE_CODE_BUDGET budget. " +
                "Near 64KB MockK inline instrumentation fails and mocks run the real body. Move grouped suspend calls " +
                "or self-contained blocks into private helpers (each suspension point spills every live local).",
            codeLength <= SEND_MESSAGE_CODE_BUDGET,
        )
    }

    /** Code attribute lengths of every method named [name], read straight from the class file. */
    private fun methodCodeLengths(bytes: ByteArray, name: String): List<Int> {
        val input = DataInputStream(ByteArrayInputStream(bytes))
        input.readInt() // magic
        input.readUnsignedShort() // minor
        input.readUnsignedShort() // major
        val poolCount = input.readUnsignedShort()
        val utf8 = arrayOfNulls<String>(poolCount)
        var index = 1
        while (index < poolCount) {
            when (val tag = input.readUnsignedByte()) {
                1 -> utf8[index] = input.readUTF()
                3, 4, 9, 10, 11, 12, 17, 18 -> input.skipFully(4)
                5, 6 -> {
                    input.skipFully(8)
                    index++
                }
                7, 8, 16, 19, 20 -> input.skipFully(2)
                15 -> input.skipFully(3)
                else -> error("unknown constant pool tag $tag at index $index")
            }
            index++
        }
        input.skipFully(6) // access flags, this class, super class
        input.skipFully(2 * input.readUnsignedShort()) // interfaces
        repeat(input.readUnsignedShort()) { // fields
            input.skipFully(6)
            repeat(input.readUnsignedShort()) {
                input.skipFully(2)
                input.skipFully(input.readInt())
            }
        }
        val lengths = mutableListOf<Int>()
        repeat(input.readUnsignedShort()) { // methods
            input.skipFully(2)
            val methodName = utf8[input.readUnsignedShort()]
            input.skipFully(2)
            repeat(input.readUnsignedShort()) {
                val attributeName = utf8[input.readUnsignedShort()]
                val attributeLength = input.readInt()
                if (methodName == name && attributeName == "Code") {
                    input.skipFully(4) // max stack, max locals
                    lengths += input.readInt()
                    input.skipFully(attributeLength - 8)
                } else {
                    input.skipFully(attributeLength)
                }
            }
        }
        return lengths
    }

    private fun DataInputStream.skipFully(count: Int) {
        var remaining = count
        while (remaining > 0) {
            val skipped = skipBytes(remaining)
            check(skipped > 0) { "class file ended early" }
            remaining -= skipped
        }
    }

    private companion object {
        // JVM limit is 65535; MockK already failed at 65108 and at about 64.9K. The budget keeps a warning
        // margin below that cliff so growth trips this assertion instead of 85 NPEs.
        const val SEND_MESSAGE_CODE_BUDGET = 62_000
    }
}
