package ai.oriveo.community.feature.chat

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import ai.oriveo.community.R
import ai.oriveo.community.core.app.GlobalSnackbarManager
import ai.oriveo.community.core.app.UiText
import ai.oriveo.community.core.attachments.FileExtractionLimits
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentExtractionLimits
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.feature.chat.attachments.AttachmentProcessor
import io.mockk.every
import io.mockk.mockk
import java.io.ByteArrayInputStream
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The text budget is checked when a file is added: a file that would push the message's attached text over the limit
 * does not enter the composer, and the user is told on the spot.
 *
 * Import goes through the real [AttachmentProcessor] and extractor; the limits come from the same resolution used at
 * send time.
 */
@RunWith(RobolectricTestRunner::class)
class ChatAttachmentCoordinatorTextBudgetTest {

    private val half = FileExtractionLimits.DEFAULT.totalCap / 2

    @Test
    fun `a file that would put the attached text over the limit is not added and the user is told`() = runTest {
        val import = Import(model())
        import.add("a.txt", "a".repeat(half))
        import.add("b.txt", "b".repeat(half))
        assertNull("Two files summing exactly to the cap fit", import.lastNotice())

        import.add("c.txt", "c")

        assertEquals(listOf("a.txt", "b.txt"), import.pending.map { it.fileName })
        assertEquals(
            UiText.Resource(R.string.file_extraction_text_budget_exceeded, listOf("c.txt")),
            import.lastNotice(),
        )
    }

    @Test
    fun `the limit is the one the active model declares`() = runTest {
        val wide = Import(model(AttachmentExtractionLimits(totalCap = FileExtractionLimits.DEFAULT.totalCap * 3)))
        repeat(3) { wide.add("f$it.txt", "x".repeat(half)) }
        assertEquals(3, wide.pending.size)
        assertNull(wide.lastNotice())

        val tight = Import(model(AttachmentExtractionLimits(totalCap = 10)))
        tight.add("small.txt", "0123456789")
        tight.add("more.txt", "x")
        assertEquals(listOf("small.txt"), tight.pending.map { it.fileName })
        assertEquals(
            UiText.Resource(R.string.file_extraction_text_budget_exceeded, listOf("more.txt")),
            tight.lastNotice(),
        )
    }

    @Test
    fun `without a resolvable connection nothing is refused at add time`() = runTest {
        val import = Import(model(), provider = null)
        repeat(3) { import.add("f$it.txt", "x".repeat(FileExtractionLimits.DEFAULT.totalCap)) }
        assertEquals(3, import.pending.size)
        assertNull(import.lastNotice())
    }

    private fun model(limits: AttachmentExtractionLimits? = null) = AIModel(
        id = "relay-model",
        name = "Relay Model",
        capabilities = listOf(ModelCapability.Text, ModelCapability.File),
        attachmentExtraction = limits,
    )

    private class Import(
        model: AIModel,
        provider: Provider? = Provider(
            id = "relay-1",
            kind = ProviderKind.Relay,
            apiKey = "k",
            baseUrlText = "https://relay.test/v1",
            relayRequested = RelayRequestedConfig(transport = RelayTransport.OpenAIChatCompletions),
            models = listOf(model),
        ),
    ) {
        val pending = mutableListOf<Attachment>()
        private val files = mutableMapOf<String, String>()
        private val snackbars = GlobalSnackbarManager()
        private val resolver = mockk<ContentResolver> {
            every { query(any(), any(), any(), any(), any()) } returns null
            every { getType(any()) } returns "text/plain"
            every { openInputStream(any()) } answers {
                ByteArrayInputStream(files.getValue(firstArg<Uri>().lastPathSegment!!).toByteArray())
            }
        }
        private val context = mockk<Context> { every { contentResolver } returns resolver }
        private val coordinator = ChatAttachmentCoordinator(
            attachmentProcessor = AttachmentProcessor(
                attachmentStore = mockk<AttachmentStore>(relaxed = true),
            ),
            globalSnackbarManager = snackbars,
            activeProviderKind = { provider?.kind },
            activeModel = { model },
            pendingAttachments = { pending },
            addAttachment = { attachment, _ -> pending += attachment },
            presentAttachmentSizeLimitDialog = {},
            activeProvider = { provider },
        )

        suspend fun add(name: String, content: String) {
            files[name] = content
            coordinator.processFile(context, Uri.parse("content://com.example.docs/$name"))
        }

        fun lastNotice(): UiText? = snackbars.active.value?.message?.message
    }
}
