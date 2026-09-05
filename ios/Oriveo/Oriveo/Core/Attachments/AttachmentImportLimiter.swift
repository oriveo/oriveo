import Foundation

nonisolated struct AttachmentImportLimiter: Sendable {
    nonisolated struct Result: Sendable {
        let accepted: [Attachment]
        let rejectedCount: Int
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
