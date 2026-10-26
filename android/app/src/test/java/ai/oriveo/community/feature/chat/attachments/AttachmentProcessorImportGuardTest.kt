package ai.oriveo.community.feature.chat.attachments

import ai.oriveo.community.core.provider.AttachmentInputGate
import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ModelCapability
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.model.ProviderConnectionState
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.model.RelayRequestedConfig
import ai.oriveo.community.core.model.RelayTransport
import ai.oriveo.community.core.provider.RelayRuntimeSupport
import ai.oriveo.community.feature.chat.ChatModelCapabilityResolver
import io.mockk.every
import io.mockk.mockk
import java.io.InputStream
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Two memory guards for attachment import (both stem from a crash when the heap hit its limit):
 * - an OOM during the read degrades to an import failure instead of escaping as an uncaught Error and killing the app;
 * - files that are certain to be rejected after reading (video / unsupported extensions) are refused before the stream is opened,
 *   so a 25MB payload is no longer pulled into the heap just to show an error.
 */
@RunWith(RobolectricTestRunner::class)
class AttachmentProcessorImportGuardTest {

    @Test
    fun `file import surfaces an error instead of crashing when the read runs out of memory`() = runTest {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )

        val outcome = processor.processFile(
            context = contextReading { throw OutOfMemoryError("Failed to allocate") },
            uri = Uri.parse("content://com.example.docs/notes.txt"),
            inputGate = AttachmentInputGate.NONE,
            activeModel = null,
            currentFileCount = 0,
        )

        val error = outcome as AttachmentImportOutcome.FileExtractionError
        assertEquals(ExtractionErrorCode.ExtractionError, error.code)
        assertEquals("notes.txt", error.fileName)
    }

    @Test
    fun `image import stays silent instead of crashing when the read runs out of memory`() = runTest {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )

        val outcome = processor.processImage(
            context = contextReading { throw OutOfMemoryError("Failed to allocate") },
            uri = Uri.parse("content://com.example.docs/photo.jpg"),
        )

        assertTrue(outcome is AttachmentImportOutcome.Silent)
    }

    @Test
    fun `unsupported video is rejected without ever opening the stream`() = runTest {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val context = contextRefusingToOpen()

        val outcome = processor.processFile(
            context = context,
            uri = Uri.parse("content://com.example.docs/clip.mp4"),
            inputGate = AttachmentInputGate.NONE,
            activeModel = null,
            currentFileCount = 0,
        )

        assertTrue(outcome is AttachmentImportOutcome.AttachmentConflict)
    }

    @Test
    fun `unsupported extension is rejected without ever opening the stream`() = runTest {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val context = contextRefusingToOpen()

        val outcome = processor.processFile(
            context = context,
            uri = Uri.parse("content://com.example.docs/archive.dmg"),
            inputGate = AttachmentInputGate.NONE,
            activeModel = null,
            currentFileCount = 0,
        )

        assertTrue(outcome is AttachmentImportOutcome.UnsupportedFile)
    }

    @Test
    fun `relay native video import uses the same gate and is not blocked with the connection identity`() = runTest {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val resolver = ChatModelCapabilityResolver(
            metadata = MetadataClient(),
            runtimeConfigProvider = {
                MetadataClient.RelayRuntimeConfig(
                    version = "test",
                    officialProviderWhitelist = emptyList(),
                    transportEnvelopes = mapOf(
                        RelayRuntimeSupport.TransportKey.GEMINI_GENERATE_CONTENT to MetadataClient.RelayTransportEnvelope(
                            image = true, nativeFile = true, textFileInline = true, webSearch = false, reasoning = false,
                        ),
                    ),
                    transportRules = emptyMap(),
                    verificationPolicy = MetadataClient.RelayVerificationPolicy(),
                    featureGatingPolicy = MetadataClient.RelayFeatureGatingPolicy(),
                )
            },
        )
        val relay = Provider(
            id = "relay",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.GeminiGenerateContent,
                resolvedAPIBaseURL = "https://relay.example.com/v1beta",
            ),
        )
        val model = AIModel(id = "plain", name = "plain", capabilities = listOf(ModelCapability.Text))
        val identity = CapabilityEvidenceIdentity(
            partitionId = "partition",
            connectionInstanceId = relay.id,
            connectionGeneration = "generation",
            credentialEpoch = "epoch",
            providerKind = relay.kind.rawValue,
            authMode = relay.authMode.rawValue,
        )

        val withIdentity = processor.processFile(
            context = contextWithBytes("video/mp4", byteArrayOf(0, 0, 0, 24, 102, 116, 121, 112)),
            uri = Uri.parse("content://com.example.docs/clip.mp4"),
            inputGate = resolver.attachmentInputGate(relay, model, identity),
            activeModel = model,
            currentFileCount = 0,
        )
        assertTrue("With a connection identity: relay native video is attachable per the projection and not blocked at import", withIdentity is AttachmentImportOutcome.Success)

        val withoutIdentity = processor.processFile(
            context = contextRefusingToOpen(),
            uri = Uri.parse("content://com.example.docs/clip.mp4"),
            inputGate = resolver.attachmentInputGate(relay, model),
            activeModel = model,
            currentFileCount = 0,
        )
        assertTrue("Without an identity it fails closed and is blocked before any bytes are read", withoutIdentity is AttachmentImportOutcome.AttachmentConflict)
    }

    @Test
    fun `relay chat video imports even when the envelope blocks native files`() = runTest {
        val processor = AttachmentProcessor(
            attachmentStore = mockk<AttachmentStore>(relaxed = true),
        )
        val (resolver, relay, model, identity) = relayChatWithoutNativeFile()
        val gate = resolver.attachmentInputGate(relay, model, identity)

        val video = processor.processFile(
            context = contextWithBytes("video/mp4", byteArrayOf(0, 0, 0, 24, 102, 116, 121, 112)),
            uri = Uri.parse("content://com.example.docs/clip.mp4"),
            inputGate = gate,
            activeModel = model,
            currentFileCount = 0,
        )
        assertTrue("video_input and file_input do not stack: the envelope blocks native files but not video, actual $video", video is AttachmentImportOutcome.Success)
        assertEquals(ai.oriveo.community.core.model.AttachmentKind.Video, (video as AttachmentImportOutcome.Success).attachment.kind)

        // Native PDF is still blocked by file_input: the projection marks file as not attachable (only the inline text path remains).
        assertFalse("Envelope nativeFile=false: native PDF is not attachable", gate.nativeFile)
    }

    private data class RelayFixture(
        val resolver: ChatModelCapabilityResolver,
        val relay: Provider,
        val model: AIModel,
        val identity: CapabilityEvidenceIdentity,
    )

    /** Relay Chat transport: envelope nativeFile=false, and video has no envelope slot (verdict unknown). */
    private fun relayChatWithoutNativeFile(): RelayFixture {
        val resolver = ChatModelCapabilityResolver(
            metadata = MetadataClient(),
            runtimeConfigProvider = {
                MetadataClient.RelayRuntimeConfig(
                    version = "test",
                    officialProviderWhitelist = emptyList(),
                    transportEnvelopes = mapOf(
                        RelayRuntimeSupport.TransportKey.OPENAI_CHAT_COMPLETIONS to MetadataClient.RelayTransportEnvelope(
                            image = true, nativeFile = false, textFileInline = true, webSearch = false, reasoning = false,
                        ),
                    ),
                    transportRules = emptyMap(),
                    verificationPolicy = MetadataClient.RelayVerificationPolicy(),
                    featureGatingPolicy = MetadataClient.RelayFeatureGatingPolicy(),
                )
            },
        )
        val relay = Provider(
            id = "relay-chat",
            kind = ProviderKind.Relay,
            status = ProviderConnectionState.Connected,
            relayRequested = RelayRequestedConfig(
                transport = RelayTransport.OpenAIChatCompletions,
                resolvedAPIBaseURL = "https://relay.example.com/v1",
            ),
        )
        val model = AIModel(id = "plain", name = "plain", capabilities = listOf(ModelCapability.Text))
        val identity = CapabilityEvidenceIdentity(
            partitionId = "partition",
            connectionInstanceId = relay.id,
            connectionGeneration = "generation",
            credentialEpoch = "epoch",
            providerKind = relay.kind.rawValue,
            authMode = relay.authMode.rawValue,
        )
        return RelayFixture(resolver, relay, model, identity)
    }

    @Test
    fun `file picker mime list no longer offers video`() {
        assertTrue(AttachmentImportPolicy.pickerMimeTypes.none { it.startsWith("video/") })
        assertTrue(AttachmentImportPolicy.videoPickerMimeTypes.contains("video/*"))
    }

    /**
     * Fails as soon as openInputStream is called. This says "this path must not read content" more directly than verify,
     * and does not drag in unrelated checks such as getContentResolver().
     */
    private fun contextRefusingToOpen(): Context {
        val resolver = mockk<ContentResolver> {
            every { query(any(), any(), any(), any(), any()) } returns null
            every { getType(any()) } returns null
            every { openInputStream(any()) } answers {
                throw AssertionError("stream must not be opened for a file that is rejected on metadata alone")
            }
        }
        return mockk<Context> { every { contentResolver } returns resolver }
    }

    private fun contextWithBytes(mimeType: String, bytes: ByteArray): Context {
        val resolver = mockk<ContentResolver> {
            every { query(any(), any(), any(), any(), any()) } returns null
            every { getType(any()) } returns mimeType
            every { openInputStream(any()) } answers { bytes.inputStream() }
        }
        return mockk<Context> { every { contentResolver } returns resolver }
    }

    /** query returns null: the file name falls back to lastPathSegment and the size is unknown, which lands exactly on the read branch. */
    private fun contextReading(read: () -> Int): Context {
        val stream = object : InputStream() {
            override fun read(): Int = read()
            override fun read(b: ByteArray, off: Int, len: Int): Int = read()
        }
        val resolver = mockk<ContentResolver> {
            every { query(any(), any(), any(), any(), any()) } returns null
            every { getType(any()) } returns "text/plain"
            every { openInputStream(any()) } returns stream
        }
        return mockk<Context> { every { contentResolver } returns resolver }
    }
}
