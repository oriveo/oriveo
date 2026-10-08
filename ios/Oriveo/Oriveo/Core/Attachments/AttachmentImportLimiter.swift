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
