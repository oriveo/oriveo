package ai.oriveo.community.core.data.attachment

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import androidx.exifinterface.media.ExifInterface
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Camera photos store pixels in sensor order and rely on EXIF Orientation to tell viewers how to
 * rotate them. saveImage re-encodes to JPEG, which drops EXIF, so it has to rotate the pixels
 * first or chat attachments end up sideways.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AttachmentStoreExifOrientationTest {
    private val context = RuntimeEnvironment.getApplication()

    /** An 80×40 landscape JPEG, red on the left half and blue on the right, tagged [orientation]. */
    private fun cameraJpeg(orientation: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(80, 40, Bitmap.Config.ARGB_8888)
        for (x in 0 until 80) for (y in 0 until 40) {
            bitmap.setPixel(x, y, if (x < 40) Color.RED else Color.BLUE)
        }
        val file = File.createTempFile("camera", ".jpg", context.cacheDir)
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
        ExifInterface(file.absolutePath).apply {
            setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())
            saveAttributes()
        }
        return file.readBytes().also { file.delete() }
    }

    private fun isRed(color: Int) = Color.red(color) > 180 && Color.blue(color) < 80
    private fun isBlue(color: Int) = Color.blue(color) > 180 && Color.red(color) < 80

    @Test
    fun `rotate 90 camera photo is stored upright for both image and thumbnail`() {
        val store = AttachmentStore(context)
        val id = store.saveImage(cameraJpeg(ExifInterface.ORIENTATION_ROTATE_90))

        listOf(store.loadImageBytes(id)!!, store.loadThumbnailBytes(id)!!).forEach { bytes ->
            val saved = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            assertTrue("expected portrait: ${saved.width}x${saved.height}", saved.height > saved.width)
            // 90° clockwise: the red left side moves to the top, the blue right side to the bottom
            assertTrue(isRed(saved.getPixel(saved.width / 2, saved.height / 5)))
            assertTrue(isBlue(saved.getPixel(saved.width / 2, saved.height * 4 / 5)))
            // Pixels are already upright, so the file must not carry a tag that makes viewers rotate again
            val orientation = ExifInterface(bytes.inputStream())
                .getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED)
            assertTrue(
                "orientation=$orientation",
                orientation == ExifInterface.ORIENTATION_UNDEFINED || orientation == ExifInterface.ORIENTATION_NORMAL,
            )
        }
    }

    @Test
    fun `normal photo keeps its orientation`() {
        val store = AttachmentStore(context)
        val id = store.saveImage(cameraJpeg(ExifInterface.ORIENTATION_NORMAL))
        val bytes = store.loadImageBytes(id)!!
        val saved = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)

        assertEquals(80, saved.width)
        assertEquals(40, saved.height)
        assertTrue(isRed(saved.getPixel(10, 20)))
        assertTrue(isBlue(saved.getPixel(70, 20)))
    }

    @Test
    fun `every non normal orientation maps to a matrix`() {
        // Readers and galleries all follow this table; a wrong entry produces a mirrored image
        assertEquals(null, exifOrientationMatrix(ExifInterface.ORIENTATION_NORMAL))
        listOf(
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL,
            ExifInterface.ORIENTATION_ROTATE_180,
            ExifInterface.ORIENTATION_FLIP_VERTICAL,
            ExifInterface.ORIENTATION_TRANSPOSE,
            ExifInterface.ORIENTATION_ROTATE_90,
            ExifInterface.ORIENTATION_TRANSVERSE,
            ExifInterface.ORIENTATION_ROTATE_270,
        ).forEach { assertTrue("$it", exifOrientationMatrix(it) != null) }
    }
}
