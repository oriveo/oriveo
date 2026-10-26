package ai.oriveo.community.core.capability

import ai.oriveo.community.R
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.AttachmentInputGate
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade.InputCapabilityConnection
import ai.oriveo.community.core.capability.truth.InputCapabilityProjections
import ai.oriveo.community.feature.chat.composer.ComposerAttachmentEntryModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.runBlocking
import org.junit.Test

/** First-attachment hint: shown once per device per provider|model, regardless of media type. */
class InputCapabilityHintStoreTest {
    private var payload: String? = null
    private val store = InputCapabilityHintStore(readPayload = { payload }, writePayload = { payload = it })

    @Test
    fun `same provider and model hints only once`() {
        assertTrue(store.consume("p1", "m1"))
        assertTrue(store.hasShown("p1", "m1"))
        assertFalse(store.consume("p1", "m1"))
    }

    @Test
    fun `switching model or provider hints again`() {
        assertTrue(store.consume("p1", "m1"))
        assertTrue(store.consume("p1", "m2"))
        assertTrue(store.consume("p2", "m1"))
        assertFalse(store.consume("p1", "m2"))
    }

    @Test
    fun `unknown projection hints once per model across media`() {
        val entry = ComposerAttachmentEntryModel.from(unknownProjections(), AttachmentInputGate(image = true, nativeFile = true, video = true))
        val nativeModel = model("m1").copy(nativeFileMimes = listOf(DOC_MIME))
        assertEquals(
            R.string.capability_input_hint_first_attach_image,
            entry.firstAttachHintRes(image(), provider, nativeModel, store),
        )
        // Recorded per model, not per media type: attaching a native file to the same model no longer shows the hint.
        assertNull(entry.firstAttachHintRes(nativeDoc(), provider, nativeModel, store))
        assertEquals(
            R.string.capability_input_hint_first_attach_file,
            entry.firstAttachHintRes(nativeDoc(), provider, nativeModel.copy(id = "m2"), store),
        )
    }

    @Test
    fun `text inline file neither hints nor records and a later image still hints`() {
        val entry = ComposerAttachmentEntryModel.from(unknownProjections(), AttachmentInputGate(image = true, nativeFile = true, textFileInline = true, video = true))
        val txt = Attachment(id = "txt-1", kind = AttachmentKind.File, fileName = "notes.txt", mimeType = "text/plain", base64Data = "aGVsbG8=")
        assertNull(entry.firstAttachHintRes(txt, provider, model("m1"), store))
        assertFalse(store.hasShown("p1", "m1"))
        assertEquals(
            R.string.capability_input_hint_first_attach_image,
            entry.firstAttachHintRes(image(), provider, model("m1"), store),
        )
        assertTrue(store.hasShown("p1", "m1"))
    }

    @Test
    fun `consume_reads_prefs_off_main`() {
        lateinit var ioThread: Thread
        val io = java.util.concurrent.Executors.newSingleThreadExecutor { Thread(it, "hint-io").also { thread -> ioThread = thread } }
        try {
            var payload: String? = null
            val readThreads = mutableListOf<Thread>()
            val store = InputCapabilityHintStore(
                readPayload = { readThreads += Thread.currentThread(); payload },
                writePayload = { payload = it },
                ioDispatcher = io.asCoroutineDispatcher(),
            )
            val callerThread = Thread.currentThread()
            assertTrue(runBlocking { store.consumeOffMain("p1", "m1") })
            assertFalse(runBlocking { store.consumeOffMain("p1", "m1") })
            assertEquals(listOf(ioThread, ioThread), readThreads)
            assertFalse(callerThread in readThreads)
            assertEquals("p1|m1", payload)
        } finally {
            io.shutdown()
        }
    }

    private val provider = Provider(id = "p1", kind = ProviderKind.OpenAI)

    private fun model(id: String) = AIModel(id = id, name = id)

    private fun image() = Attachment(id = "img-1", kind = AttachmentKind.Image, fileName = "photo.png", mimeType = "image/png")

    private fun nativeDoc() = Attachment(
        id = "doc-1",
        kind = AttachmentKind.File,
        fileName = "brief.doc",
        mimeType = DOC_MIME,
        base64Data = "ZG9j",
        originalBase64Data = "ZG9j",
    )

    private fun unknownProjections(): InputCapabilityProjections {
        fun project(key: String) = CapabilityEvidenceFacade.projectInputCapability(
            key = key,
            verdict = null,
            endImplements = true,
            override = null,
            negativeCacheHit = false,
            connection = InputCapabilityConnection.OFFICIAL,
        )
        return InputCapabilityProjections(
            vision = project(CapabilityEvidenceFacade.VISION_INPUT),
            file = project(CapabilityEvidenceFacade.FILE_INPUT),
            video = project(CapabilityEvidenceFacade.VIDEO_INPUT),
        )
    }

    private companion object {
        const val DOC_MIME = "application/msword"
    }
}
