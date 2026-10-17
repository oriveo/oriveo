package ai.oriveo.community.core.data.attachment

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.util.Base64
import androidx.exifinterface.media.ExifInterface
import androidx.test.core.app.ApplicationProvider
import ai.oriveo.community.core.data.repository.streaming.StreamingImageProcessor
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Generated and imported images must be stored as-is. They used to share the photo picker's compression path,
 * so a high-resolution generated image ended up as a 1536px JPEG 70 still labeled image/png.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AttachmentStoreOriginalImageTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    private fun png(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.GREEN)
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        }
    }

    private fun decode(bytes: ByteArray): Bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)

    @Test
    fun `original image is stored byte for byte with its real mime and a small thumbnail`() {
        val store = AttachmentStore(context)
        val source = png(2048, 1024)

        val stored = store.saveOriginalImage(source)!!

        assertEquals("image/png", stored.mimeType)
        assertArrayEquals(source, store.loadImageBytes(stored.id))
        val thumb = decode(store.loadThumbnailBytes(stored.id)!!)
        assertTrue("thumb=${thumb.width}x${thumb.height}", maxOf(thumb.width, thumb.height) <= 120)
    }

    @Test
    fun `compressed image is downscaled jpeg and says so`() {
        val store = AttachmentStore(context)

        val stored = store.saveCompressedImage(png(2048, 1024))!!

        assertEquals("image/jpeg", stored.mimeType)
        val saved = store.loadImageBytes(stored.id)!!
        assertEquals("image/jpeg", BitmapFactory.Options().apply { inJustDecodeBounds = true }
            .also { BitmapFactory.decodeByteArray(saved, 0, saved.size, it) }.outMimeType)
        assertEquals(1536, decode(saved).width)
    }

    @Test
    fun `undecodable bytes leave no file behind`() {
        val store = AttachmentStore(context)
        val garbage = "not an image".toByteArray()

        assertNull(store.saveOriginalImage(garbage, id = "garbage-original"))
        assertNull(store.saveCompressedImage(garbage, id = "garbage-compressed"))
        assertFalse(store.hasImage("garbage-original"))
        assertFalse(store.hasImage("garbage-compressed"))
    }

    @Test
    fun `original image with rotation exif is stored upright at full size`() {
        val store = AttachmentStore(context)
        val bitmap = Bitmap.createBitmap(200, 100, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.RED) }
        val file = File.createTempFile("rotated", ".jpg", context.cacheDir)
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        ExifInterface(file.absolutePath).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            saveAttributes()
        }
        val source = file.readBytes().also { file.delete() }

        val stored = store.saveOriginalImage(source)!!

        assertEquals("image/jpeg", stored.mimeType)
        val saved = decode(store.loadImageBytes(stored.id)!!)
        assertEquals(100, saved.width)
        assertEquals(200, saved.height)
    }

    @Test
    fun `generated image keeps full resolution through the streaming persist path`() = runTest {
        val store = AttachmentStore(context)
        val generated = Attachment(
            id = "gen-1",
            kind = AttachmentKind.Image,
            fileName = "generated.png",
            mimeType = "image/png",
            base64Data = Base64.encodeToString(png(2048, 2048), Base64.NO_WRAP),
        )

        val persisted = StreamingImageProcessor(store).persistInlineBase64(listOf(generated)).single()

        assertNull(persisted.base64Data)
        assertEquals("image/png", persisted.mimeType)
        assertNotNull(persisted.thumbnailBase64)
        val saved = decode(store.loadImageBytes(persisted.localImageId!!)!!)
        assertEquals(2048, saved.width)
        assertEquals(2048, saved.height)
    }
}
