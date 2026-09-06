package ai.oriveo.community.feature.chat.components

import android.content.Context
import android.graphics.Bitmap
import android.util.Base64
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.ui.component.ImageViewerSheet
import ai.oriveo.community.ui.component.decodeSampledBitmap
import ai.oriveo.community.ui.component.rememberAttachmentDisplayBitmap
import ai.oriveo.community.ui.component.rememberAttachmentThumbnailBitmap
import ai.oriveo.community.ui.component.saveImageToGallery
import ai.oriveo.community.ui.component.shareImage
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.Dispatchers
import org.koin.compose.koinInject
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.max

@Composable
private fun rememberThumbnailBitmap(attachment: Attachment): androidx.compose.ui.graphics.ImageBitmap? {
    return rememberAttachmentThumbnailBitmap(attachment)
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun UserImageHero(
    attachment: Attachment,
    gallery: List<Attachment> = listOf(attachment),
    index: Int = 0,
    immersiveHero: Boolean = false,
    hasText: Boolean = false,
    attachmentStore: AttachmentStore = koinInject(),
) {

    val shape: androidx.compose.ui.graphics.Shape = when {
        immersiveHero && hasText -> RoundedCornerShape(
            topStart = 20.dp, topEnd = 20.dp,
            bottomStart = 0.dp, bottomEnd = 0.dp,
        )
        immersiveHero -> RoundedCornerShape(
            topStart = 20.dp, topEnd = 20.dp,
            bottomStart = 20.dp, bottomEnd = 6.dp,
        )
        else -> RoundedCornerShape(14.dp)
    }
    val bitmap = rememberAttachmentDisplayBitmap(attachment)
    var showViewer by remember(attachment.id) { mutableStateOf(false) }
    var menuExpanded by remember(attachment.id) { mutableStateOf(false) }
    val isAccessible = hasAccessibleImageData(attachment)

    val clickableModifier = Modifier.combinedClickable(
        enabled = isAccessible,
        onClick = { showViewer = true },
        onLongClick = { menuExpanded = true },
    )

    Box {
        if (bitmap != null) {
            val aspectRatio = remember(bitmap) {
                bitmap.width.toFloat() / max(bitmap.height.toFloat(), 1f)
            }

            val isPortrait = aspectRatio < 0.7f
            val sizingModifier = if (isPortrait) {
                Modifier
                    .height(240.dp)
                    .aspectRatio(aspectRatio)
            } else {
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 240.dp)
                    .aspectRatio(aspectRatio)
            }
            androidx.compose.foundation.Image(
                bitmap = bitmap,
                contentDescription = attachment.fileName,
                contentScale = androidx.compose.ui.layout.ContentScale.Fit,
                modifier = sizingModifier
                    .clip(shape)
                    .then(clickableModifier),
            )
        } else {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 120.dp, max = 240.dp)
                    .aspectRatio(4f / 3f)
                    .clip(shape)
                    .then(clickableModifier)
                    .background(Color.White.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Image,
                    contentDescription = null,
                    modifier = Modifier.size(36.dp),
                    tint = Color.White.copy(alpha = 0.6f),
                )
            }
        }

        ImageContextDropdown(
            attachment = attachment,
            expanded = menuExpanded,
            onDismiss = { menuExpanded = false },

            attachmentStore = attachmentStore,
        )
    }

    if (showViewer) {
        ImageViewerSheet(
            attachments = gallery,
            initialIndex = index,
            onDismiss = { showViewer = false },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun UserImageGridCell(
    attachment: Attachment,
    gallery: List<Attachment> = listOf(attachment),
    index: Int = 0,
    overflowCount: Int = 0,
    attachmentStore: AttachmentStore = koinInject(),
) {
    val shape = RoundedCornerShape(12.dp)
    val bitmap = rememberThumbnailBitmap(attachment)
    var showViewer by remember(attachment.id) { mutableStateOf(false) }
    var menuExpanded by remember(attachment.id) { mutableStateOf(false) }
    val isAccessible = hasAccessibleImageData(attachment)

    val cellModifier = Modifier
        .size(128.dp)
        .clip(shape)
        .combinedClickable(
            enabled = isAccessible,
            onClick = { showViewer = true },
            onLongClick = { menuExpanded = true },
        )

    Box(modifier = cellModifier) {
        if (bitmap != null) {
            androidx.compose.foundation.Image(
                bitmap = bitmap,
                contentDescription = attachment.fileName,
                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.White.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Image,
                    contentDescription = null,
                    modifier = Modifier.size(28.dp),
                    tint = Color.White.copy(alpha = 0.6f),
                )
            }
        }

        if (overflowCount > 0) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.55f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = "+$overflowCount",
                    color = Color.White,
                    style = OriveoTheme.typography.title1,
                )
            }
        }

        ImageContextDropdown(
            attachment = attachment,
            expanded = menuExpanded,
            onDismiss = { menuExpanded = false },

            attachmentStore = attachmentStore,
        )
    }

    if (showViewer) {
        ImageViewerSheet(
            attachments = gallery,
            initialIndex = index,
            onDismiss = { showViewer = false },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun UserImageThumbnail(
    attachment: Attachment,
    gallery: List<Attachment> = listOf(attachment),
    index: Int = 0,
    attachmentStore: AttachmentStore = koinInject(),
) {
    val shape = RoundedCornerShape(12.dp)
    val bitmap = rememberThumbnailBitmap(attachment)
    var showViewer by remember(attachment.id) { mutableStateOf(false) }
    var menuExpanded by remember(attachment.id) { mutableStateOf(false) }
    val isAccessible = hasAccessibleImageData(attachment)

    val cellModifier = Modifier
        .size(96.dp)
        .clip(shape)
        .combinedClickable(
            enabled = isAccessible,
            onClick = { showViewer = true },
            onLongClick = { menuExpanded = true },
        )

    Box(modifier = cellModifier) {
        if (bitmap != null) {
            androidx.compose.foundation.Image(
                bitmap = bitmap,
                contentDescription = attachment.fileName,
                contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.White.copy(alpha = 0.18f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Image,
                    contentDescription = null,
                    modifier = Modifier.size(28.dp),
                    tint = Color.White.copy(alpha = 0.6f),
                )
            }
        }

        ImageContextDropdown(
            attachment = attachment,
            expanded = menuExpanded,
            onDismiss = { menuExpanded = false },

            attachmentStore = attachmentStore,
        )
    }

    if (showViewer) {
        ImageViewerSheet(
            attachments = gallery,
            initialIndex = index,
            onDismiss = { showViewer = false },
        )
    }
}

@Composable
private fun ImageContextDropdown(
    attachment: Attachment,
    expanded: Boolean,
    onDismiss: () -> Unit,
    attachmentStore: AttachmentStore,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(
            text = { Text(stringResource(R.string.save_to_photos)) },
            onClick = {
                onDismiss()
                scope.launch {
                    val bmp = loadAttachmentBitmap(context, attachmentStore, attachment) ?: return@launch
                    saveImageToGallery(context, bmp)
                }
            },
        )
        DropdownMenuItem(
            text = { Text(stringResource(R.string.share)) },
            onClick = {
                onDismiss()
                scope.launch {
                    val bmp = loadAttachmentBitmap(context, attachmentStore, attachment) ?: return@launch
                    shareImage(context, bmp)
                }
            },
        )
    }
}

private suspend fun loadAttachmentBitmap(context: Context, attachmentStore: AttachmentStore, attachment: Attachment): Bitmap? {
    val bytes = loadImageAttachmentBytes(context, attachmentStore, attachment) ?: return null
    return withContext(Dispatchers.Default) {
        decodeSampledBitmap(bytes, maxDecodeEdgePx = 2_048, preferRgb565 = false)
    }
}

private suspend fun loadImageAttachmentBytes(context: Context, attachmentStore: AttachmentStore, attachment: Attachment): ByteArray? {
    return withContext(Dispatchers.IO) {
        attachment.localImageId?.let { localImageId ->
            attachmentStore.loadImageBytes(localImageId)?.let { return@withContext it }
        }

        attachment.base64Data
            ?.takeIf { it.isNotBlank() && !it.startsWith("http") }
            ?.let { base64 ->
                runCatching { Base64.decode(base64, Base64.DEFAULT) }.getOrNull()?.let { return@withContext it }
            }

        null
    }
}
