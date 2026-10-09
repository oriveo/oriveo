import Foundation

nonisolated struct AttachmentImportLimiter: Sendable {
    nonisolated struct Result: Sendable {
        let accepted: [Attachment]
        let rejectedCount: Int
    }

    nonisolated struct BoundedImport: Sendable {
        let accepted: [Attachment]
        /// Sources skipped without being read because every slot was already taken.
        let skippedOverLimit: Int
    }

    /// Imports one source at a time and stops once the slots are full — **the remaining sources are never read**.
    ///
    /// The file picker allows multiple selection. Reading and extracting every selected file and only then
    /// truncating to the attachment limit is expensive: besides its extracted text, each PDF / Office attachment
    /// carries a base64 copy of the original file (up to about 40 MB), so picking ten large files would hold all
    /// ten in memory just to drop seven, which is enough for the system to kill the app for memory pressure.
    /// A source that fails to import does not take a slot; the next one is tried.
    nonisolated static func importSequentially<Source>(
        _ sources: [Source],
        availableSlots: Int,
        importOne: (Source) async -> Attachment?
    ) async -> BoundedImport {
        var accepted: [Attachment] = []
        var skipped = 0
        for source in sources {
            guard accepted.count < availableSlots else {
                skipped += 1
                continue
            }
            if let attachment = await importOne(source) {
                accepted.append(attachment)
            }
        }
        return BoundedImport(accepted: accepted, skippedOverLimit: skipped)
    }

    nonisolated static func limit(
        existing: [Attachment],
        incoming: [Attachment],
        maxAttachments: Int
    ) -> Result {
        guard maxAttachments > 0 else {
            return Result(accepted: [], rejectedCount: incoming.count)
        }

        let availableSlots = max(maxAttachments - existing.count, 0)
        guard availableSlots > 0 else {
            return Result(accepted: [], rejectedCount: incoming.count)
        }

        if incoming.count <= availableSlots {
            return Result(accepted: incoming, rejectedCount: 0)
        }

        return Result(
            accepted: Array(incoming.prefix(availableSlots)),
            rejectedCount: incoming.count - availableSlots
        )
    }
}

/// What goes back into the composer when a sent user message is edited.
nonisolated struct ComposerEditDraft: Sendable {
    let text: String
    /// The original message's attachments, converted into composer attachments that can be sent again (see `ComposerAttachmentRestoration`).
    let attachments: [Attachment]
}

nonisolated enum ComposerAttachmentRestoration {
    /// Turns a sent message's attachments back into composer attachments.
    ///
    /// The original message is deleted by the edit, so what goes back into the composer is an independent copy:
    /// a new attachment id, and images saved again under a new local id (reusing the old id would leave the
    /// copy pointing at an image the edit is about to remove).
    /// Attachments whose content cannot be read on this device (a file whose body is not stored here) are not put back, since they could not be sent anyway.
    static func restoredForComposer(_ attachments: [Attachment], partitionUID: String) -> [Attachment] {
        attachments.compactMap { original in
            var copy = original
            copy.id = UUID()
            switch original.kind {
            case .image:
                // Images imported on this device are keyed by localImageID; otherwise the original is stored under the attachment id.
                let sourceKey = original.localImageID ?? original.id.uuidString
                guard let data = ImageStore.loadImageData(for: sourceKey, partitionUID: partitionUID) else {
                    return nil
                }
                let imageID = UUID().uuidString
                ImageStore.save(imageData: data, for: imageID, partitionUID: partitionUID)
                if let thumbnail = ImageStore.loadThumbnailData(for: sourceKey, partitionUID: partitionUID) {
                    ImageStore.saveThumbnail(imageData: thumbnail, for: imageID, partitionUID: partitionUID)
                } else {
                    ImageStore.generateAndSaveThumbnail(from: data, for: imageID, partitionUID: partitionUID)
                }
                copy.localImageID = imageID
            case .file, .video:
                // A file whose extraction failed (a scanned PDF) never had body text; it is delivered through its error code or its original bytes.
                let hasBody = original.base64Data?.isEmpty == false
                let hasOriginal = original.originalBase64Data?.isEmpty == false
                guard hasBody || hasOriginal || original.extractionErrorCode != nil else { return nil }
            }
            return copy
        }
    }
}
