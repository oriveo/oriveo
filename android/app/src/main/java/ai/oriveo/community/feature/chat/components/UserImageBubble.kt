package ai.oriveo.community.feature.chat.components

import android.content.Context
import android.graphics.Bitmap
import android.util.Base64
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import ai.oriveo.community.R
import ai.oriveo.community.core.data.attachment.AttachmentStore
import ai.oriveo.community.core.attachments.AttachmentDelivery
import ai.oriveo.community.core.capability.InputNegativeCache
import ai.oriveo.community.core.capability.truth.ProviderForm
import ai.oriveo.community.core.capability.truth.relayInputIdentity
import ai.oriveo.community.core.capability.truth.resolveInputCapabilityProjections
import ai.oriveo.community.core.data.remote.MetadataClient
import ai.oriveo.community.core.data.repository.resolveSendModelSelection
import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.CapabilityEvidenceIdentity
import ai.oriveo.community.core.model.ChatMessage
import ai.oriveo.community.core.model.ChatRole
import ai.oriveo.community.core.model.Provider
import ai.oriveo.community.core.provider.CapabilityEvidenceFacade
import ai.oriveo.community.core.provider.CapabilityEvidenceObservationBridge
import ai.oriveo.community.core.provider.ProviderSelectionSnapshot
import ai.oriveo.community.ui.component.ImageViewerSheet
import ai.oriveo.community.ui.component.decodeSampledBitmap
import ai.oriveo.community.ui.component.rememberAttachmentDisplayBitmap
import ai.oriveo.community.ui.component.rememberAttachmentThumbnailBitmap
import ai.oriveo.community.ui.component.rememberGlobalSnackbarManager
import ai.oriveo.community.ui.component.saveImageToGallery
import ai.oriveo.community.ui.component.shareImage
import ai.oriveo.community.ui.theme.OriveoTheme
import kotlinx.coroutines.Dispatchers
import org.koin.compose.koinInject
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.max

/** Load state of the local connection identity for a Relay bubble: a null while the identity is still being fetched does not mean "unavailable". */
internal sealed interface RelayBubbleIdentity {
    /** Still fetching; no mark is shown, so "not sent" does not flash when the bubble enters composition. */
    data object Loading : RelayBubbleIdentity

    /** Fetch finished; a null identity really means it could not be obtained, and the outbound request writes the placeholder under the three-key hard block. */
    data class Resolved(val identity: CapabilityEvidenceIdentity?) : RelayBubbleIdentity
}

/**
 * Attachments in a user bubble that this model will not receive and the outbound request replaces with a
 * placeholder, mapped to their annotation text (attachment id to string resource).
 * A read-only projection (the same [resolveInputCapabilityProjections] as the outbound request); it does not
 * change local messages. The model is taken from the connection and model this message was sent to
 * ([ChatMessage.providerID] / [ChatMessage.modelID]).
 * - Image / video: marked when that key has outbound=placeholder.
 * - File: when file_input is a placeholder, a file with usable extracted text is still injected as text (it
 *   counts as sent); only files with no text to send are marked.
 * - Relay: applies the same projection with the conversation connection's local identity ([relayLocalIdentity],
 *   dispatched through [relayInputIdentity]); nothing is marked while the identity is still loading
 *   ([RelayBubbleIdentity.Loading]); once loaded as null, the outbound request writes the placeholder under the
 *   three-key hard block, so the null is handed to the same projection and marked consistently.
 * - Image-generation path where the body is rewritten as a whole: not marked.
 */
internal fun userAttachmentNotSentMarks(
    message: ChatMessage,
    provider: Provider?,
    metadataClient: MetadataClient = MetadataClient.instance,
    negativeCache: InputNegativeCache = InputNegativeCache.shared,
    relayLocalIdentity: RelayBubbleIdentity = RelayBubbleIdentity.Loading,
): Map<String, Int> {
    if (message.role != ChatRole.User || provider == null) return emptyMap()
    val attachments = message.attachments.orEmpty()
    if (attachments.isEmpty()) return emptyMap()
    val modelId = message.modelID?.trim()?.takeIf { it.isNotEmpty() } ?: return emptyMap()
    val model = ProviderSelectionSnapshot.selectedModel(provider, modelId, metadataClient)
        ?: AIModel(id = modelId, name = message.modelName.ifBlank { modelId })
    // Same criterion as the send side: on the image-generation path the body is rewritten as a whole.
    if (resolveSendModelSelection(provider, modelId).supportsImageGen) return emptyMap()
    val relayIdentity = if (ProviderForm.of(provider) == ProviderForm.Relay) {
        val local = relayLocalIdentity as? RelayBubbleIdentity.Resolved ?: return emptyMap()
        relayInputIdentity(provider, model, local.identity)
    } else {
        null
    }
    val inputs = resolveInputCapabilityProjections(
        provider = provider,
        model = model,
        relayIdentity = relayIdentity,
        metadataClient = metadataClient,
        negativeCache = negativeCache,
    ) ?: return emptyMap()
    fun placeholder(key: String) = inputs[key].outbound == CapabilityEvidenceFacade.InputCapabilityOutbound.PLACEHOLDER
    return attachments.mapNotNull { attachment ->
        val notSent = when (attachment.kind) {
            AttachmentKind.Image -> placeholder(CapabilityEvidenceFacade.VISION_INPUT)
            AttachmentKind.Video -> placeholder(CapabilityEvidenceFacade.VIDEO_INPUT)
            AttachmentKind.File -> placeholder(CapabilityEvidenceFacade.FILE_INPUT) && !AttachmentDelivery.hasUsableText(attachment)
        }
        if (notSent) attachment.id to R.string.capability_input_bubble_not_sent_to_model else null
    }.toMap()
}

/**
 * Recomposition cache for [userAttachmentNotSentMarks]: the projection is recomputed only when the message,
 * connection, Relay identity, negative-cache revision, metadata refresh, or capability-evidence revision changes.
 * The key must include the negative-cache revision, otherwise the mark does not refresh after a rejection; it
 * must also include the capability-evidence revision so the mark is recomputed when model facts refresh on their own.
 */
@Composable
internal fun rememberUserAttachmentNotSentMarks(
    message: ChatMessage,
    provider: Provider?,
    relayLocalIdentity: RelayBubbleIdentity,
    metadataClient: MetadataClient = MetadataClient.instance,
    negativeCache: InputNegativeCache = InputNegativeCache.shared,
): Map<String, Int> {
    val negativeCacheRevision by negativeCache.revision.collectAsState()
    val metadataRefresh by metadataClient.refreshEvents.collectAsState(initial = null)
    val capabilityEvidenceRevision by CapabilityEvidenceObservationBridge.revision.collectAsState()
    return remember(
        message.id,
        message.role,
        message.modelID,
        message.modelName,
        message.attachments,
        provider,
        relayLocalIdentity,
        negativeCacheRevision,
        metadataRefresh,
        capabilityEvidenceRevision,
    ) {
        userAttachmentNotSentMarks(message, provider, metadataClient, negativeCache, relayLocalIdentity)
    }
}

/** Strip pinned to the bottom of an image: "Not sent to this model". */
@Composable
private fun BoxScope.NotSentToModelOverlay(mark: Int) {
    Text(
        text = stringResource(mark),
        style = OriveoTheme.typography.caption,
        color = Color.White,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier
            .align(Alignment.BottomStart)
            .fillMaxWidth()
            .background(Color.Black.copy(alpha = 0.55f))
            .padding(horizontal = 6.dp, vertical = 3.dp),
    )
}

/**
 * Decodes a thumbnail Bitmap from an Attachment.
 * Prefers thumbnailBase64, falling back to localImageId / image base64Data from disk or memory.
 */
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
    /** When non-null, marks "Not sent to this model" at the bottom of the image ([userAttachmentNotSentMarks]). */
    notSentMark: Int? = null,
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

        notSentMark?.let { NotSentToModelOverlay(it) }

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
    /** When non-null, marks "Not sent to this model" at the bottom of the image ([userAttachmentNotSentMarks]). */
    notSentMark: Int? = null,
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

        notSentMark?.let { NotSentToModelOverlay(it) }

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
    /** When non-null, marks "Not sent to this model" at the bottom of the image ([userAttachmentNotSentMarks]). */
    notSentMark: Int? = null,
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

        notSentMark?.let { NotSentToModelOverlay(it) }

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
    val snackbar = rememberGlobalSnackbarManager()
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(
            text = { Text(stringResource(R.string.save_to_photos)) },
            onClick = {
                onDismiss()
                scope.launch {
                    val bmp = loadAttachmentBitmap(context, attachmentStore, attachment) ?: return@launch
                    saveImageToGallery(context, bmp, snackbar)
                }
            },
        )
        DropdownMenuItem(
            text = { Text(stringResource(R.string.share)) },
            onClick = {
                onDismiss()
                scope.launch {
                    val bmp = loadAttachmentBitmap(context, attachmentStore, attachment) ?: return@launch
                    shareImage(context, bmp, snackbar)
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
