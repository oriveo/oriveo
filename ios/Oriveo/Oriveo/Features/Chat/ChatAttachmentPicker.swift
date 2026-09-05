import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatAttachmentPicker {
    enum ImportResult {
        case imported(Attachment)
        case oversized
        case unsupported
        case extractionFailed(reason: ExtractionErrorCode, fileName: String)
    }

    struct ImportContext: Sendable {
        let attachmentSupport: RelayRuntimeSupport.AttachmentSupport

        init(provider: Provider?) {
            guard let provider else {
                attachmentSupport = (image: false, video: false, nativeFile: false, textFileInline: false)
                return
            }

            if provider.kind == .relay,
               let runtime = RelayRuntimeSupport.attachmentSupport(
                for: provider,
                runtimeConfig: MetadataClient.shared.syncRelayRuntimeConfig()
               ) {
                attachmentSupport = runtime
            } else {
                attachmentSupport = provider.kind.attachmentSupport
            }
        }

        init(providerKind: ProviderKind?) {
            attachmentSupport = providerKind?.attachmentSupport ?? (image: false, video: false, nativeFile: false, textFileInline: false)
        }
    }


    @ViewBuilder
    static func attachmentThumbnail(
        _ attachment: Attachment,
        onRemove: @escaping (UUID) -> Void,
        onTapKnowledgeCTA: (() -> Void)? = nil
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == .image {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        OriveoTheme.Palette.surfaceChrome,
                                        OriveoTheme.Palette.surfaceElevated
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        ThumbnailImageView(
                            attachment: attachment,
                            partitionUID: AppSessionStore.activeUID
                        )
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                .clear,
                                                OriveoTheme.Palette.overlay
                                            ],
                                            startPoint: .center,
                                            endPoint: .bottom
                                        )
                                    )
                                    .allowsHitTesting(false)
                            }
                    }
                    .frame(width: 68, height: 68)
                    .overlay(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        OriveoTheme.Palette.cardHighlight.opacity(0.26),
                                        .clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: OriveoTheme.Palette.shadow.opacity(0.045), radius: 8, y: 3)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                OriveoTheme.Palette.primarySoft,
                                                OriveoTheme.Palette.surfaceElevated
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )

                                Image(systemName: "doc.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(OriveoTheme.Palette.primary)
                            }
                            .frame(width: 28, height: 28)

                            Spacer(minLength: 0)

                            if let ext = fileExtensionLabel(for: attachment.fileName) {
                                Text(ext)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                    .padding(.horizontal, 6)
                                    .frame(height: 18)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(OriveoTheme.Palette.surfaceInset)
                                    )
                            }
                        }

                        Spacer(minLength: 0)

                        Text(displayFileName(for: attachment.fileName))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .lineLimit(extractedInfoLabel(for: attachment) == nil ? 2 : 1)
                            .multilineTextAlignment(.leading)

                        if let info = extractedInfoLabel(for: attachment) {
                            Text(info)
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        if attachment.extractedTruncated == true, let onTapKnowledgeCTA {
                            Button(action: onTapKnowledgeCTA) {
                                Text(L10n.tr("file_extraction_truncated_cta_knowledge", table: .chat))
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(OriveoTheme.Palette.primary)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .frame(
                        width: 82,
                        height: (attachment.extractedTruncated == true && onTapKnowledgeCTA != nil) ? 102 : 68,
                        alignment: .topLeading
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        OriveoTheme.Palette.surfaceChrome,
                                        OriveoTheme.Palette.surfaceElevated
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        OriveoTheme.Palette.cardHighlight.opacity(0.24),
                                        .clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: OriveoTheme.Palette.shadow.opacity(0.04), radius: 8, y: 3)
                }
            }

            Button {
                onRemove(attachment.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .frame(width: 19, height: 19)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: OriveoTheme.Palette.shadow.opacity(0.10), radius: 5, y: 2)
            }
            .offset(x: 5, y: -5)
        }
    }

    private static func fileExtensionLabel(for fileName: String) -> String? {
        let ext = URL(fileURLWithPath: fileName).pathExtension.uppercased()
        guard !ext.isEmpty else { return nil }
        return String(ext.prefix(4))
    }

    private static func displayFileName(for fileName: String) -> String {
        let url = URL(fileURLWithPath: fileName)
        let baseName = url.deletingPathExtension().lastPathComponent
        return baseName.isEmpty ? fileName : baseName
    }

    private static func extractedInfoLabel(for attachment: Attachment) -> String? {
        guard let lines = attachment.extractedTotalLines, lines > 0 else { return nil }
        if attachment.extractedTruncated == true {
            return String(format: L10n.tr("file_extraction_chip_extracted_lines", table: .chat), lines) + " ⚠︎"
        }
        return String(format: L10n.tr("file_extraction_chip_extracted_lines", table: .chat), lines)
    }


    static func processPhotoItem(
        _ item: PhotosPickerItem,
        byteLimit: Int? = nil,
        partitionUID: String? = nil
    ) async -> ImportResult {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return .unsupported }
        guard ChatAttachmentImportPolicy.isWithinSizeLimit(data.count, customLimit: byteLimit) else {
            return .oversized
        }
        guard let image = downsampleImageData(data, maxPixelSize: 1_536) else { return .unsupported }
        return encodeImageAttachment(
            image,
            byteLimit: byteLimit,
            normalizeOrientation: false,
            partitionUID: partitionUID
        )
    }

    nonisolated static func downsampleImageData(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard maxPixelSize > 0 else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)
            .map { CGFloat(truncating: $0) } ?? maxPixelSize
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)
            .map { CGFloat(truncating: $0) } ?? maxPixelSize
        let boundedPixelSize = min(maxPixelSize, max(width, height))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: boundedPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    nonisolated static func processCapturedImage(
        _ image: UIImage,
        byteLimit: Int? = nil,
        partitionUID: String? = nil
    ) -> ImportResult {
        encodeImageAttachment(
            image,
            byteLimit: byteLimit,
            normalizeOrientation: true,
            partitionUID: partitionUID
        )
    }

    nonisolated private static func encodeImageAttachment(
        _ source: UIImage,
        byteLimit: Int?,
        normalizeOrientation: Bool,
        partitionUID: String?
    ) -> ImportResult {
        let image = normalizeOrientation ? normalizeImageOrientation(source) : source

        let maxDim: CGFloat = 1536
        let scale = min(maxDim / max(image.size.width, image.size.height), 1.0)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.7) else { return .unsupported }
        if normalizeOrientation,
           !ChatAttachmentImportPolicy.isWithinSizeLimit(jpeg.count, customLimit: byteLimit) {
            return .oversized
        }

        let imageID = UUID().uuidString
        ImageStore.save(imageData: jpeg, for: imageID, partitionUID: partitionUID)

        let ts = min(120 / max(image.size.width, image.size.height), 1.0)
        let thumbSize = CGSize(width: image.size.width * ts, height: image.size.height * ts)
        let tr = UIGraphicsImageRenderer(size: thumbSize)
        let thumb = tr.image { _ in image.draw(in: CGRect(origin: .zero, size: thumbSize)) }
        let thumbData = thumb.jpegData(compressionQuality: 0.5)
        if let thumbData {
            ImageStore.saveThumbnail(imageData: thumbData, for: imageID, partitionUID: partitionUID)
        }

        return .imported(Attachment(
            id: UUID(), kind: .image, fileName: "image.jpg", mimeType: "image/jpeg",
            localImageID: imageID,
            thumbnailBase64: thumbData?.base64EncodedString()
        ))
    }

    nonisolated private static func normalizeImageOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(at: .zero) }
    }


    static func processFileURL(_ url: URL, providerKind: ProviderKind?) async -> ImportResult {
        await processFileURL(url, importContext: ImportContext(providerKind: providerKind))
    }

    static func processFileURL(
        _ url: URL,
        importContext: ImportContext,
        byteLimit: Int? = nil,
        extractionLimits: FileExtractionLimits = .default
    ) async -> ImportResult {
        let data: Data
        do {
            data = try SecurityScopedFileAccess.withAccess(to: url) {
                try BoundedFileReader.data(
                    at: url,
                    maxBytes: ChatAttachmentImportPolicy.effectiveMaxBytes(customLimit: byteLimit)
                )
            }
        } catch BoundedFileReadError.tooLarge {
            return .oversized
        } catch {
            return .unsupported
        }

        let fileName = url.lastPathComponent
        let detectedMimeType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
            .preferredMIMEType
        guard ChatAttachmentImportPolicy.isSupportedFile(fileName: fileName, detectedMimeType: detectedMimeType) else {
            return .unsupported
        }

        let ext = url.pathExtension.lowercased()
        let resolvedMime = ChatAttachmentImportPolicy.resolveMimeType(
            fileName: fileName,
            detectedMimeType: detectedMimeType
        )
        let isSupportedTextFile = FileTextExtractor.supportedMimes.contains(resolvedMime.lowercased())
            || FileTextExtractor.textExtensions.contains(ext)
            || ["pdf", "epub", "html", "htm", "rtf", "docx", "xlsx", "pptx",
                "odt", "ods", "odp"].contains(ext)

        if isSupportedTextFile && !resolvedMime.hasPrefix("video/") {
            do {
                let extracted = try FileTextExtractor.extract(
                    data: data,
                    fileName: fileName,
                    mimeType: resolvedMime,
                    limits: extractionLimits
                )
                let textData = Data(extracted.content.utf8)
                let base64Text = autoreleasepool { textData.base64EncodedString() }
                let originalBase64: String? = shouldPersistOriginalBase64(mime: resolvedMime)
                    ? autoreleasepool { data.base64EncodedString() }
                    : nil
                return .imported(Attachment(
                    id: UUID(), kind: .file, fileName: fileName,
                    mimeType: resolvedMime,
                    base64Data: base64Text,
                    thumbnailBase64: nil,
                    extractedTotalLines: extracted.totalLines,
                    extractedTruncated: extracted.truncated,
                    extractedSizeBytes: extracted.sizeBytes,
                    originalBase64Data: originalBase64
                ))
            } catch let e as ExtractionError {
                if shouldPersistOriginalBase64(mime: resolvedMime), shouldDeferToNative(errorCode: e.code) {
                    let originalBase64 = autoreleasepool { data.base64EncodedString() }
                    return .imported(Attachment(
                        id: UUID(), kind: .file, fileName: fileName,
                        mimeType: resolvedMime,
                        base64Data: "",
                        thumbnailBase64: nil,
                        extractedSizeBytes: data.count,
                        extractionErrorCode: e.code.rawValue,
                        originalBase64Data: originalBase64
                    ))
                }
                return .extractionFailed(reason: e.code, fileName: fileName)
            } catch {
                return .extractionFailed(reason: .extractionError, fileName: fileName)
            }
        }

        let support = importContext.attachmentSupport

        let mimeType = ChatAttachmentImportPolicy.resolveMimeType(
            fileName: fileName,
            detectedMimeType: detectedMimeType
        )

        if mimeType.hasPrefix("video/") {
            guard support.video else { return .unsupported }
            let base64 = autoreleasepool { data.base64EncodedString() }
            return .imported(Attachment(
                id: UUID(), kind: .video, fileName: fileName,
                mimeType: mimeType, base64Data: base64, thumbnailBase64: nil
            ))
        }

        if !support.nativeFile {
            guard String(data: data, encoding: .utf8) != nil else { return .unsupported }
        }

        let base64 = autoreleasepool { data.base64EncodedString() }
        return .imported(Attachment(
            id: UUID(), kind: .file, fileName: fileName,
            mimeType: mimeType, base64Data: base64, thumbnailBase64: nil
        ))
    }

    private static func shouldPersistOriginalBase64(mime: String) -> Bool {
        let normalized = mime.lowercased()
        return normalized == "application/pdf"
            || normalized == "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            || normalized == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            || normalized == "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            || normalized == "application/rtf"
            || normalized == "text/rtf"
            || normalized == "application/vnd.oasis.opendocument.text"
            || normalized == "application/vnd.oasis.opendocument.spreadsheet"
            || normalized == "application/vnd.oasis.opendocument.presentation"
    }

    private static func shouldDeferToNative(errorCode: ExtractionErrorCode) -> Bool {
        errorCode == .scannedPdf
    }

    static func fallbackMIMEType(for ext: String) -> String {
        ChatAttachmentImportPolicy.fallbackMIMEType(for: ext)
    }
}
