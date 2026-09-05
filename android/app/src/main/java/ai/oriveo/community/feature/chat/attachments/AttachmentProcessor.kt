package ai.oriveo.community.feature.chat.attachments

import android.content.Context
import android.net.Uri
import android.util.Base64
import ai.oriveo.community.core.attachments.ExtractionErrorCode
import ai.oriveo.community.core.attachments.ExtractionException
import ai.oriveo.community.core.attachments.FileExtractionLimits
import ai.oriveo.community.core.attachments.FileTextExtractor
import ai.oriveo.community.core.attachments.extractors.OfficeTextExtractor
import ai.oriveo.community.core.attachments.shouldPersistOriginalBase64
import ai.oriveo.community.core.data.attachment.AttachmentStore

import ai.oriveo.community.core.model.AIModel
import ai.oriveo.community.core.model.Attachment
import ai.oriveo.community.core.model.AttachmentKind
import ai.oriveo.community.core.model.ProviderKind
import ai.oriveo.community.core.provider.MessageBuilder
import ai.oriveo.community.core.util.generateUuidString
import ai.oriveo.community.core.util.InputSizeLimitExceededException
import ai.oriveo.community.core.util.UNKNOWN_INPUT_SIZE
import ai.oriveo.community.core.util.readBytesLimited
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Result of importing one attachment.
 *
 * processImage and processFile keep the IO and byte handling out of the ViewModel, which only has
 * to map an outcome onto a UI effect such as a snackbar or a dialog.
 */
sealed class AttachmentImportOutcome {
    data class Success(val attachment: Attachment, val source: String) : AttachmentImportOutcome()
    data object Oversized : AttachmentImportOutcome()
    data object UnsupportedFile : AttachmentImportOutcome()
    data object AttachmentConflict : AttachmentImportOutcome()
    data class FileCountLimitExceeded(val fileName: String) : AttachmentImportOutcome()
    data class FileExtractionError(
        val code: ExtractionErrorCode,
        val fileName: String,
        val partial: Attachment?,
    ) : AttachmentImportOutcome()
    data object Silent : AttachmentImportOutcome()
}

class AttachmentProcessor(
    private val attachmentStore: AttachmentStore,
) {
    private data class ImageImportReadResult(
        val localId: String?,
        val thumbnail: String?,
        val oversized: Boolean,
    )

    /** Metadata read from the ContentResolver only; it never touches the file contents. */
    private data class FileImportMeta(
        val fileName: String,
        val detectedMimeType: String?,
        val rawSize: Long?,
    )

    private data class FileImportReadResult(
        val bytes: ByteArray?,
        val oversized: Boolean,
    )

    /** Imports a URI from the image picker: compress, build a thumbnail, create the Attachment. */
    suspend fun processImage(context: Context, uri: Uri): AttachmentImportOutcome {
        return try {
            val mimeType = context.contentResolver.getType(uri) ?: "image/jpeg"
            val fileName = uri.lastPathSegment ?: "image.jpg"

            
            val rawSize = withContext(Dispatchers.IO) {
                AttachmentImportPolicy.byteSizeFor(context.contentResolver, uri)
            }
            val readResult = withContext(Dispatchers.IO) {
                if (AttachmentImportPolicy.isOversized(AttachmentImportPolicy.byteSizeFor(context.contentResolver, uri))) {
                    return@withContext ImageImportReadResult(null, null, true)
                }
                val bytes = try {
                    context.contentResolver.openInputStream(uri)?.use {
                        it.readBytesLimited(
                            maxBytes = AttachmentImportPolicy.MAX_ATTACHMENT_BYTES,
                            expectedBytes = rawSize ?: UNKNOWN_INPUT_SIZE,
                        )
                    }
                } catch (_: InputSizeLimitExceededException) {
                    return@withContext ImageImportReadResult(null, null, true)
                } ?: return@withContext ImageImportReadResult(null, null, false)
                if (!AttachmentImportPolicy.isWithinSizeLimit(bytes.size)) {
                    return@withContext ImageImportReadResult(null, null, true)
                }
                val resolvedLocalId = attachmentStore.saveImage(bytes, mimeType)
                ImageImportReadResult(
                    localId = resolvedLocalId,
                    thumbnail = attachmentStore.loadThumbnailBase64(resolvedLocalId),
                    oversized = false,
                )
            }
            if (readResult.oversized) return AttachmentImportOutcome.Oversized
            val localId = readResult.localId ?: return AttachmentImportOutcome.Silent

            
            
            
            
            AttachmentImportOutcome.Success(
                attachment = Attachment(
                    id = generateUuidString(),
                    kind = AttachmentKind.Image,
                    fileName = fileName,
                    mimeType = mimeType,
                    localImageId = localId,
                    thumbnailBase64 = readResult.thumbnail,
                ),
                source = "photo_library",
            )
        } catch (_: Exception) {
            AttachmentImportOutcome.Silent
        } catch (_: OutOfMemoryError) {
            
            
            AttachmentImportOutcome.Silent
        }
    }

    /** Imports a URI from the file picker: read the contents, base64 encode, create the Attachment. */
    suspend fun processFile(
        context: Context,
        uri: Uri,
        activeProviderKind: ProviderKind?,
        activeModel: AIModel?,
        currentFileCount: Int,
    ): AttachmentImportOutcome {
        
        var resolvedFileName = ""
        return try {
            
            
            val meta = withContext(Dispatchers.IO) {
                FileImportMeta(
                    fileName = AttachmentImportPolicy.fileNameFor(context.contentResolver, uri),
                    detectedMimeType = context.contentResolver.getType(uri),
                    rawSize = AttachmentImportPolicy.byteSizeFor(context.contentResolver, uri),
                )
            }
            resolvedFileName = meta.fileName
            val fileName = meta.fileName
            val detectedMimeType = meta.detectedMimeType
            val rawSize = meta.rawSize

            if (AttachmentImportPolicy.isOversized(rawSize)) return AttachmentImportOutcome.Oversized
            if (!AttachmentImportPolicy.isSupportedFile(fileName, detectedMimeType)) {
                return AttachmentImportOutcome.UnsupportedFile
            }

            val mimeType = AttachmentImportPolicy.resolveMimeType(
                fileName = fileName,
                detectedMimeType = detectedMimeType,
            )
            val isVideo = mimeType.lowercase().startsWith("video/")
            val ext = fileName.substringAfterLast('.', "").lowercase()

            
            
            if (isVideo && !MessageBuilder.canAttachVideo(activeProviderKind, mimeType)) {
                return AttachmentImportOutcome.AttachmentConflict
            }

            
            val isExtractable = ext in FileTextExtractor.textExtensions ||
                mimeType in FileTextExtractor.supportedMimes ||
                ext == "pdf" || ext == "epub" || ext in setOf("html", "htm", "rtf") ||
                OfficeTextExtractor.isOfficeFile(ext) ||
                ext in setOf("odt", "ods", "odp")
            val limits = FileExtractionLimits.resolve(activeModel)
            
            if (isExtractable && currentFileCount >= limits.maxFiles) {
                return AttachmentImportOutcome.FileCountLimitExceeded(fileName)
            }

            
            val readResult = withContext(Dispatchers.IO) {
                val b = try {
                    context.contentResolver.openInputStream(uri)?.use {
                        it.readBytesLimited(
                            maxBytes = AttachmentImportPolicy.MAX_ATTACHMENT_BYTES,
                            expectedBytes = rawSize ?: UNKNOWN_INPUT_SIZE,
                        )
                    }
                } catch (_: InputSizeLimitExceededException) {
                    return@withContext FileImportReadResult(null, true)
                }
                val actualOversized = b != null && !AttachmentImportPolicy.isWithinSizeLimit(b.size)
                FileImportReadResult(
                    bytes = b,
                    oversized = actualOversized,
                )
            }
            if (readResult.oversized) return AttachmentImportOutcome.Oversized
            val bytes = readResult.bytes ?: return AttachmentImportOutcome.Silent

            if (isVideo) {
                
                
                val rawContentRef = withContext(Dispatchers.IO) { attachmentStore.saveBlob(bytes) }
                return AttachmentImportOutcome.Success(
                    attachment = Attachment(
                        id = generateUuidString(),
                        kind = AttachmentKind.Video,
                        fileName = fileName,
                        mimeType = mimeType,
                        rawContentRef = rawContentRef,
                    ),
                    source = "video",
                )
            }

            if (isExtractable) {
                try {
                    val extracted = withContext(Dispatchers.IO) {
                        FileTextExtractor.extract(bytes, fileName, mimeType, limits)
                    }
                    val textBytes = extracted.content.toByteArray(Charsets.UTF_8)
                    val base64 = withContext(Dispatchers.Default) {
                        Base64.encodeToString(textBytes, Base64.NO_WRAP)
                    }
                    
                    // Keep the original bytes so a model that can read this format natively gets
                    // the real file rather than extracted text.
                    
                    
                    val rawContentRef = if (shouldPersistOriginalBase64(mimeType)) {
                        withContext(Dispatchers.IO) { attachmentStore.saveBlob(bytes) }
                    } else null
                    
                    
                    return AttachmentImportOutcome.Success(
                        attachment = Attachment(
                            id = generateUuidString(),
                            kind = AttachmentKind.File,
                            fileName = fileName,
                            mimeType = mimeType,
                            base64Data = base64,
                            extractedTotalLines = extracted.totalLines,
                            extractedTruncated = extracted.truncated,
                            extractedSizeBytes = extracted.sizeBytes,
                            rawContentRef = rawContentRef,
                        ),
                        source = "file",
                    )
                } catch (e: ExtractionException) {
                    
                    
                    val partial = if (e.code == ExtractionErrorCode.ScannedPdf && shouldPersistOriginalBase64(mimeType)) {
                        val rawContentRef = withContext(Dispatchers.IO) { attachmentStore.saveBlob(bytes) }
                        Attachment(
                            id = generateUuidString(),
                            kind = AttachmentKind.File,
                            fileName = fileName,
                            mimeType = mimeType,
                            base64Data = "",
                            extractedSizeBytes = bytes.size,
                            rawContentRef = rawContentRef,
                            extractionErrorCode = e.code.raw,
                        )
                    } else null
                    return AttachmentImportOutcome.FileExtractionError(
                        code = e.code,
                        fileName = fileName,
                        partial = partial,
                    )
                }
            } else {
                
                val base64 = withContext(Dispatchers.Default) {
                    Base64.encodeToString(bytes, Base64.NO_WRAP)
                }
                if (!MessageBuilder.canAttachFile(activeProviderKind, mimeType, base64)) {
                    return AttachmentImportOutcome.AttachmentConflict
                }
                
                
                
                val rawContentRef = withContext(Dispatchers.IO) { attachmentStore.saveBlob(bytes) }
                return AttachmentImportOutcome.Success(
                    attachment = Attachment(
                        id = generateUuidString(),
                        kind = AttachmentKind.File,
                        fileName = fileName,
                        mimeType = mimeType,
                        rawContentRef = rawContentRef,
                    ),
                    source = "file",
                )
            }
        } catch (_: Exception) {
            AttachmentImportOutcome.Silent
        } catch (_: OutOfMemoryError) {
            
            
            
            AttachmentImportOutcome.FileExtractionError(
                code = ExtractionErrorCode.ExtractionError,
                fileName = resolvedFileName.ifEmpty { fallbackFileName(uri) },
                partial = null,
            )
        }
    }

    /** The OOM path must not query the ContentResolver, which reads from disk on the main thread, so it falls back to the plain uri string. */
    private fun fallbackFileName(uri: Uri): String =
        uri.lastPathSegment?.substringAfterLast('/')?.trim()?.takeIf { it.isNotEmpty() } ?: "file"
}
