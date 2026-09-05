package ai.oriveo.community.ui.component

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import android.widget.Toast
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.DisableSelection
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.max

@Immutable
private data class ViewerImageState(
    val bitmap: Bitmap? = null,
    val hasFullImage: Boolean = false,
    val isLoadingFullImage: Boolean = false,
)

/**
 * Full-screen image viewer.
 *
 * Single-image entry point, for callers that hold the bytes rather than an attachment.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImageViewerSheet(
    imageData: ByteArray?,
    thumbnailBase64: String?,
    onDismiss: () -> Unit,
) {
    ImageViewerSheetImpl(
        attachments = null,
        initialIndex = 0,
        singleImageData = imageData,
        singleThumbnailBase64 = thumbnailBase64,
        onDismiss = onDismiss,
    )
}

/**
 * Multi-image entry point: swiping horizontally pages through the whole set.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImageViewerSheet(
    attachments: List<Attachment>,
    initialIndex: Int,
    onDismiss: () -> Unit,
) {
    ImageViewerSheetImpl(
        attachments = attachments,
        initialIndex = initialIndex.coerceIn(0, (attachments.size - 1).coerceAtLeast(0)),
        singleImageData = null,
        singleThumbnailBase64 = null,
        onDismiss = onDismiss,
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ImageViewerSheetImpl(
    attachments: List<Attachment>?,
    initialIndex: Int,
    singleImageData: ByteArray?,
    singleThumbnailBase64: String?,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val spacing = OriveoTheme.spacing
    val pageCount = attachments?.size ?: 1
    val pagerState = rememberPagerState(initialPage = initialIndex) { pageCount }

    // Sampling target for the viewer: twice the longest screen edge. Nothing beyond that is
    // resolvable on the panel, so a 48-100MP camera original gains nothing from being decoded larger
    // and costs a great deal of heap for the privilege.
    val viewerMaxDecodeEdgePx = with(LocalDensity.current) {
        max(context.resources.displayMetrics.widthPixels, context.resources.displayMetrics.heightPixels) * 2
    }

    var savedToPhotos by remember { mutableStateOf(false) }
    // Bitmap of the page currently on screen, which the toolbar saves or shares.
    var currentBitmap by remember { mutableStateOf<Bitmap?>(null) }

    // ModalBottomSheet owns a separate layout root. Clear any inherited SelectionContainer registrar
    // so hosting this viewer below selectable chat text can never register cross-root Text nodes.
    DisableSelection {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            sheetState = sheetState,
            containerColor = Color.Black,
            dragHandle = null,
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black),
            ) {
                if (attachments != null && attachments.isNotEmpty()) {
                    HorizontalPager(
                        state = pagerState,
                        modifier = Modifier.fillMaxSize(),
                    ) { page ->
                        ImageViewerPage(
                            attachment = attachments[page],
                            isVisible = page == pagerState.currentPage,
                            maxDecodeEdgePx = viewerMaxDecodeEdgePx,
                            onFullBitmapLoaded = { bmp ->
                                if (page == pagerState.currentPage) currentBitmap = bmp
                            },
                        )
                    }
                    // On a page change, drop the toolbar's bitmap until the new page reports its
                    // own; otherwise saving would write the image the user just swiped away from.
                    LaunchedEffect(pagerState.currentPage) {
                        currentBitmap = null
                    }
                } else {
                    // Single-image path. Decoding runs on IO with sampling either way: a synchronous
                    // decode of a large original on the main thread stalls the frame and can exhaust
                    // the heap outright.
                    val singleBitmap by produceState<Bitmap?>(
                        initialValue = null,
                        singleImageData,
                        singleThumbnailBase64,
                        viewerMaxDecodeEdgePx,
                    ) {
                        value = withContext(Dispatchers.IO) {
                            when {
                                singleImageData != null ->
                                    decodeSampledBitmap(singleImageData, viewerMaxDecodeEdgePx, preferRgb565 = false)
                                singleThumbnailBase64 != null -> runCatching {
                                    val bytes = Base64.decode(singleThumbnailBase64, Base64.DEFAULT)
                                    decodeSampledBitmap(bytes, viewerMaxDecodeEdgePx, preferRgb565 = false)
                                }.getOrNull()
                                else -> null
                            }
                        }
                    }
                    LaunchedEffect(singleBitmap) { currentBitmap = singleBitmap }

                    ZoomableImage(bitmap = singleBitmap, isLoadingOriginal = false)
                }

                // Top toolbar.
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .align(Alignment.TopCenter)
                        .padding(horizontal = spacing.lg, vertical = spacing.md),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = onDismiss) {
                        Text(
                            text = stringResource(R.string.done),
                            color = Color.White,
                            style = OriveoTheme.typography.title3,
                        )
                    }

                    Spacer(modifier = Modifier.weight(1f))

                    if (currentBitmap != null) {
                        val bmp = currentBitmap!!
                        IconButton(
                            onClick = {
                                scope.launch {
                                    saveImageToGallery(context, bmp)
                                    savedToPhotos = true
                                    delay(2000)
                                    savedToPhotos = false
                                }
                            },
                        ) {
                            Icon(
                                imageVector = if (savedToPhotos) Icons.Filled.CheckCircle else Icons.Filled.Download,
                                contentDescription = stringResource(R.string.save_to_photos),
                                modifier = Modifier.size(24.dp),
                                tint = if (savedToPhotos) OriveoTheme.colors.success else Color.White,
                            )
                        }

                        Spacer(modifier = Modifier.width(spacing.sm))

                        IconButton(onClick = { scope.launch { shareImage(context, bmp) } }) {
                            Icon(
                                imageVector = Icons.Filled.Share,
                                contentDescription = stringResource(R.string.share),
                                modifier = Modifier.size(24.dp),
                                tint = Color.White,
                            )
                        }
                    }
                }

                // Page counter, shown only when there is more than one image.
                if (attachments != null && attachments.size > 1) {
                    Box(
                        modifier = Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 36.dp)
                            .clip(RoundedCornerShape(50))
                            .background(Color.Black.copy(alpha = 0.5f))
                            .padding(horizontal = 12.dp, vertical = 6.dp),
                    ) {
                        Text(
                            text = "${pagerState.currentPage + 1} / ${attachments.size}",
                            color = Color.White,
                            style = OriveoTheme.typography.footnote,
                        )
                    }
                }
            }
        }
    }
}

/**
 * One page of the viewer: asynchronous load plus zoom and pan gestures. Gesture state is only live
 * while the page is visible, so an off-screen neighbour the pager is prefetching cannot capture
 * pointer input.
 */
@Composable
private fun ImageViewerPage(
    attachment: Attachment,
    isVisible: Boolean,
    maxDecodeEdgePx: Int,
    onFullBitmapLoaded: (Bitmap) -> Unit,
) {
    val context = LocalContext.current
    val imageState by produceState(
        initialValue = ViewerImageState(isLoadingFullImage = hasOriginalImageSource(attachment)),
        attachment.id,
        maxDecodeEdgePx,
    ) {
        // Decode the preview on IO too. produceState runs its block on the composition dispatcher by
        // default, and Base64.decode on a large preview is enough to be felt there.
        attachment.thumbnailBase64?.let { tb ->
            val thumbBitmap = withContext(Dispatchers.IO) {
                runCatching {
                    val bytes = Base64.decode(tb, Base64.DEFAULT)
                    decodeSampledBitmap(bytes, maxDecodeEdgePx, preferRgb565 = false)
                }.getOrNull()
            }
            if (thumbBitmap != null) {
                value = value.copy(bitmap = thumbBitmap)
            }
        }
        // Then the original. Sampling is not optional here: a 4K or 8K source decoded at full size
        // costs 50-200MB, and the pager keeps the neighbouring page alive as well, so two of those
        // at once exhausts the heap.
        val fullBytes = loadFullImageBytes(context, attachment)
        if (fullBytes != null) {
            val full = withContext(Dispatchers.IO) {
                decodeSampledBitmap(fullBytes, maxDecodeEdgePx, preferRgb565 = false)
            }
            if (full != null) {
                value = ViewerImageState(bitmap = full, hasFullImage = true, isLoadingFullImage = false)
                return@produceState
            }
        }
        value = value.copy(isLoadingFullImage = false)
    }

    LaunchedEffect(imageState.bitmap, imageState.hasFullImage) {
        imageState.bitmap?.let { if (isVisible && imageState.hasFullImage) onFullBitmapLoaded(it) }
    }
    LaunchedEffect(isVisible) {
        imageState.bitmap?.let { if (isVisible && imageState.hasFullImage) onFullBitmapLoaded(it) }
    }

    ZoomableImage(bitmap = imageState.bitmap, isLoadingOriginal = imageState.isLoadingFullImage && !imageState.hasFullImage)
}

@Composable
private fun ZoomableImage(bitmap: Bitmap?, isLoadingOriginal: Boolean) {
    var scale by remember(bitmap) { mutableFloatStateOf(1f) }
    var offset by remember(bitmap) { mutableStateOf(Offset.Zero) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .pointerInput(bitmap) {
                if (bitmap != null) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        scale = (scale * zoom).coerceIn(1f, 5f)
                        offset = if (scale > 1f) {
                            Offset(x = offset.x + pan.x, y = offset.y + pan.y)
                        } else {
                            Offset.Zero
                        }
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier
                    .fillMaxWidth()
                    .graphicsLayer(
                        scaleX = scale,
                        scaleY = scale,
                        translationX = offset.x,
                        translationY = offset.y,
                    ),
                contentScale = ContentScale.Fit,
            )
        } else if (!isLoadingOriginal) {
            Text(
                text = stringResource(R.string.image_not_available),
                color = Color.White.copy(alpha = 0.6f),
                style = OriveoTheme.typography.body,
            )
        }

        if (isLoadingOriginal) {
            OriginalImageLoadingBadge(
                modifier = Modifier
                    .align(if (bitmap != null) Alignment.BottomCenter else Alignment.Center)
                    .padding(bottom = if (bitmap != null) 28.dp else 0.dp),
            )
        }
    }
}

@Composable
private fun OriginalImageLoadingBadge(modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(50))
            .background(Color.Black.copy(alpha = 0.62f))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(16.dp),
            strokeWidth = 2.dp,
            color = Color.White,
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = stringResource(R.string.loading_full_image),
            color = Color.White,
            style = OriveoTheme.typography.footnote,
        )
    }
}

/**
 * Whether a full-resolution payload exists at all, which decides if the viewer shows its
 * "loading original" badge over the preview or settles on the preview immediately.
 */
private fun hasOriginalImageSource(attachment: Attachment): Boolean =
    !attachment.localImageId.isNullOrBlank() ||
        (!attachment.base64Data.isNullOrBlank() && !attachment.base64Data.startsWith("http"))

/**
 * Loads the best bytes available for one attachment, in descending order of fidelity: the original
 * in the attachment store, then inline base64, and finally the small preview so the viewer shows
 * something rather than an error.
 */
private suspend fun loadFullImageBytes(context: Context, attachment: Attachment): ByteArray? {
    return withContext(Dispatchers.IO) {
        val attachmentStore = AttachmentStore(context)

        attachment.localImageId?.let { lid ->
            attachmentStore.loadImageBytes(lid)?.let { return@withContext it }
        }

        attachment.base64Data?.takeIf { it.isNotBlank() && !it.startsWith("http") }?.let {
            runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull()?.let { return@withContext it }
        }

        attachment.thumbnailBase64?.takeIf { it.isNotBlank() }?.let {
            runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull()?.let { return@withContext it }
        }

        null
    }
}

/**
 * Saves the image into the system gallery. No WRITE_EXTERNAL_STORAGE is needed on API 29 and above
 * because MediaStore owns the file.
 *
 * The work is suspended onto Dispatchers.IO because all of it blocks: JPEG encoding at the original
 * resolution and quality 95, the Binder IPC of the MediaStore insert and update, and the disk write
 * itself. On the main thread that drops frames in proportion to image size. The failure Toast is
 * raised back on the caller's main scope, since Toast.makeText requires a thread with a Looper.
 */
internal suspend fun saveImageToGallery(context: Context, bitmap: Bitmap) {
    val saved = withContext(Dispatchers.IO) {
        try {
            val contentValues = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, "oriveo_${System.currentTimeMillis()}.jpg")
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Oriveo")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
            }

            val uri = context.contentResolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                contentValues,
            )

            uri?.let { imageUri ->
                context.contentResolver.openOutputStream(imageUri)?.use { out ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out)
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    contentValues.clear()
                    contentValues.put(MediaStore.Images.Media.IS_PENDING, 0)
                    context.contentResolver.update(imageUri, contentValues, null, null)
                }
            }
            true
        } catch (_: Exception) {
            false
        }
    }
    if (!saved) {
        Toast.makeText(context, context.getString(R.string.save_failed), Toast.LENGTH_SHORT).show()
    }
}

/**
 * Shares the image through a temporary file in the cache directory, so nothing is published into
 * MediaStore just to hand the bytes to another app.
 *
 * As with [saveImageToGallery], the JPEG encode and the cache write go to Dispatchers.IO; launching
 * the chooser and any failure Toast stay on the caller's main scope.
 */
internal suspend fun shareImage(context: Context, bitmap: Bitmap) {
    val shareUri = withContext(Dispatchers.IO) {
        try {
            val cacheDir = java.io.File(context.cacheDir, "shared_images")
            cacheDir.mkdirs()
            val tempFile = java.io.File(cacheDir, "oriveo_share.jpg")
            tempFile.outputStream().use { out ->
                bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out)
            }

            androidx.core.content.FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                tempFile,
            )
        } catch (_: Exception) {
            null
        }
    }

    try {
        if (shareUri == null) throw java.io.IOException("share image encode failed")
        val shareIntent = Intent(Intent.ACTION_SEND).apply {
            type = "image/jpeg"
            putExtra(Intent.EXTRA_STREAM, shareUri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(shareIntent, null))
    } catch (_: Exception) {
        Toast.makeText(context, context.getString(R.string.share_failed), Toast.LENGTH_SHORT).show()
    }
}
