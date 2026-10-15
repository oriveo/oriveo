import Foundation
import UIKit
import UniformTypeIdentifiers

/// Where content dropped on the chat page goes: classification, file slots, appending text to the composer.
///
/// Drops have no rules of their own: images take the camera's compression / size / partition path
/// (`ChatAttachmentPicker.processCapturedImage`), files are copied to a temporary directory and take the
/// same `processFileURLs` as the file button with the same `availableFileSlots`, and ChatView reports
/// rejections through the same function. Only the UI-free parts live here, so tests call them directly.
nonisolated enum ChatDropImport {
    /// Drop types the chat page accepts. `NSUserActivity` (a conversation row dragged out to a new window) is not one of them: dragging out of the Home sidebar
    /// across the chat page neither lights the outline nor reports "unsupported" on release.
    static let acceptedContentTypes: [UTType] = [.content, .data, .url]

    /// Describes one dropped item (taken from `NSItemProvider`, separated out for testing).
    struct Item: Equatable, Sendable {
        /// Ordered from highest to lowest fidelity (the order of `NSItemProvider.registeredTypeIdentifiers`).
        var typeIdentifiers: [String]
        var suggestedName: String?
        /// Has an open-in-place file representation (a file dragged out of the Files app).
        var isFileBacked: Bool = false
    }

    enum Kind: Equatable, Sendable {
        case image
        case file
        case text
        /// Something unknown (neither data nor text): ignored without a notice.
        case ignored
    }

    struct Plan: Equatable, Sendable {
        var imageIndices: [Int] = []
        var fileIndices: [Int] = []
        var textIndices: [Int] = []
        /// Images dropped while the current model does not accept images: the same outcome as picking an image with the file button (unsupported format).
        var unsupportedCount = 0

        /// Text is appended to the composer only when there is nothing else; mixed with images or files in one drop, the text is left alone.
        var appendsText: Bool {
            imageIndices.isEmpty && fileIndices.isEmpty && unsupportedCount == 0 && !textIndices.isEmpty
        }

        var isEmpty: Bool {
            imageIndices.isEmpty && fileIndices.isEmpty && textIndices.isEmpty && unsupportedCount == 0
        }
    }

    static func classify(_ item: Item) -> Kind {
        let types = item.typeIdentifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .image) }) {
            return .image
        }
        // Text snippets and text files both report public.text: with a file representation, or a suggested name with a supported extension, it is imported as a file
        let isText = types.contains { $0.conforms(to: .text) || $0.conforms(to: .url) }
        if isText && !looksLikeFile(item) {
            return .text
        }
        if types.contains(where: { $0.conforms(to: .data) || $0.conforms(to: .content) }) {
            return .file
        }
        return .ignored
    }

    static func plan(_ items: [Item], supportsImage: Bool) -> Plan {
        var plan = Plan()
        for (index, item) in items.enumerated() {
            switch classify(item) {
            case .image:
                if supportsImage {
                    plan.imageIndices.append(index)
                } else {
                    plan.unsupportedCount += 1
                }
            case .file:
                plan.fileIndices.append(index)
            case .text:
                plan.textIndices.append(index)
            case .ignored:
                break
            }
        }
        return plan
    }

    /// File slots: the same calculation for the file button and drops, made before reading any file (files beyond them are not read, see `AttachmentImportLimiter.importSequentially`).
    static func availableFileSlots(maxFiles: Int, pendingCount: Int) -> Int {
        max(maxFiles - pendingCount, 0)
    }

    /// Appends dropped text after the composer's existing text (on a new line), keeping the total within `maxUTF16`.
    /// What does not fit is cut by character (never splitting a grapheme cluster); when `truncated` is true the caller shows the same notice as typing past the limit.
    static func appendingDroppedText(_ dropped: String, to current: String, maxUTF16: Int) -> (text: String, truncated: Bool) {
        guard !dropped.isEmpty else { return (current, false) }
        let separator = current.isEmpty || current.last?.isNewline == true ? "" : "\n"
        let budget = maxUTF16 - current.utf16.count - separator.utf16.count
        guard budget > 0 else { return (current, true) }
        if dropped.utf16.count <= budget {
            return (current + separator + dropped, false)
        }
        var used = 0
        var end = dropped.startIndex
        for character in dropped {
            let length = character.utf16.count
            guard used + length <= budget else { break }
            used += length
            end = dropped.index(after: end)
        }
        let kept = dropped[..<end]
        guard !kept.isEmpty else { return (current, true) }
        return (current + separator + kept, true)
    }

    /// File name used when copying into the temporary directory: the drag source's suggested name first, the extension from the loaded file, otherwise one derived from the type.
    static func fileName(suggestedName: String?, loadedFileName: String, typeIdentifier: String) -> String {
        let loaded = URL(fileURLWithPath: loadedFileName)
        let loadedExtension = loaded.pathExtension
        let fallbackExtension = UTType(typeIdentifier)?.preferredFilenameExtension ?? ""
        let fileExtension = loadedExtension.isEmpty ? fallbackExtension : loadedExtension

        let trimmed = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var base = trimmed.isEmpty ? loaded.deletingPathExtension().lastPathComponent : trimmed
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if base.isEmpty { base = "file" }
        guard !fileExtension.isEmpty,
              URL(fileURLWithPath: base).pathExtension.lowercased() != fileExtension.lowercased() else {
            return base
        }
        return base + "." + fileExtension
    }

    /// The import shared by the file button and drops: one file at a time, stopping when the slots are full, counting each kind of rejection.
    static func processFileURLs(
        _ urls: [URL],
        availableSlots: Int,
        importContext: ChatAttachmentPicker.ImportContext,
        byteLimit: Int,
        extractionLimits: FileExtractionLimits
    ) async -> (attachments: [Attachment], rejectedCount: Int, oversizedCount: Int, overLimitCount: Int) {
        var rejected = 0
        var oversized = 0
        let batch = await AttachmentImportLimiter.importSequentially(urls, availableSlots: availableSlots) { url in
            switch await ChatAttachmentPicker.processFileURL(
                url,
                importContext: importContext,
                byteLimit: byteLimit,
                extractionLimits: extractionLimits
            ) {
            case .imported(let attachment):
                return attachment
            case .oversized:
                oversized += 1
            case .unsupported:
                rejected += 1
            case .extractionFailed(let code, let fileName):
                // An extraction failure (corrupted, encrypted, scanned, ...) has its own message and is not
                // counted as rejected: counting it would immediately show a second "unsupported file format"
                // toast in the same spot, and that one usually wins although the format is supported.
                Task { @MainActor in
                    ToastManager.shared.show(code.importFailureMessage(
                        fileName: fileName,
                        maxInputFileBytes: extractionLimits.maxInputFileBytes
                    ))
                }
            }
            return nil
        }
        return (batch.accepted, rejected, oversized, batch.skippedOverLimit)
    }

    private static func looksLikeFile(_ item: Item) -> Bool {
        if item.isFileBacked { return true }
        guard let name = item.suggestedName, !URL(fileURLWithPath: name).pathExtension.isEmpty else { return false }
        return ChatAttachmentImportPolicy.isSupportedFile(fileName: name, detectedMimeType: nil)
    }
}

// MARK: - Reading NSItemProvider content

extension ChatDropImport.Item {
    init(provider: NSItemProvider) {
        self.init(
            typeIdentifiers: provider.registeredTypeIdentifiers,
            suggestedName: provider.suggestedName,
            isFileBacked: !provider.registeredTypeIdentifiers(fileOptions: [.openInPlace]).isEmpty
        )
    }
}

/// Asynchronous reading of dropped items. A file representation from the system is only valid inside the callback, so files are copied into `directory` right there.
nonisolated enum ChatDropLoader {
    /// Images are decoded to bitmaps for the camera path, downsampled first to a 1536 longest edge (the same cap as encoding) so the full original is never decoded into memory.
    static func loadImage(from provider: NSItemProvider) async -> UIImage? {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
            return nil
        }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data else { return nil }
        return ChatAttachmentPicker.downsampleImageData(data, maxPixelSize: 1_536)
    }

    static func copyFile(from provider: NSItemProvider, into directory: URL) async -> URL? {
        let candidates = provider.registeredTypeIdentifiers.filter { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) || type.conforms(to: .content)
        }
        guard let type = candidates.first else { return nil }
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let name = ChatDropImport.fileName(
                    suggestedName: suggestedName,
                    loadedFileName: url.lastPathComponent,
                    typeIdentifier: type
                )
                // One subdirectory per file: files with the same name do not overwrite each other, and the name stays as is for the attachment
                let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let destination = folder.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    static func loadText(from provider: NSItemProvider) async -> String? {
        if provider.canLoadObject(ofClass: NSString.self) {
            let text: String? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    continuation.resume(returning: (object as? NSString).map { $0 as String })
                }
            }
            if let text { return text }
        }
        guard provider.canLoadObject(ofClass: NSURL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL)?.absoluteString)
            }
        }
    }

    /// The temporary directory for this drop; removed as a whole once the import finishes.
    static func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatDropImport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
