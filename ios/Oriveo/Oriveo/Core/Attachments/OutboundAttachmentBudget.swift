import Foundation

nonisolated enum OutboundAttachmentBudget {

    static let defaultBudgetBytes = 10 * 1024 * 1024

    static func apply(
        to messages: [ChatMessage],
        budgetBytes: Int = defaultBudgetBytes,
        imageRawSizeOf: (String) -> Int = { ImageStore.storedImageSize(for: $0) }
    ) -> [ChatMessage] {
        guard messages.contains(where: { !($0.attachments?.isEmpty ?? true) }) else { return messages }

        let lastUserIndex = messages.lastIndex(where: { $0.role == .user })
        var result = messages
        var used = 0

        for index in messages.indices.reversed() {
            guard let attachments = messages[index].attachments, !attachments.isEmpty else { continue }

            let exempt = index == lastUserIndex
            var kept: [Attachment] = []
            var omissions: [String] = []

            for attachment in attachments {
                let cost = costOf(attachment, imageRawSizeOf: imageRawSizeOf)
                if exempt || used + cost <= budgetBytes {
                    used += cost
                    kept.append(attachment)
                    continue
                }
                if let lightened = lighten(attachment) {
                    used += inlineCost(lightened)
                    kept.append(lightened)
                } else {
                    omissions.append(placeholder(for: attachment))
                }
            }

            guard !omissions.isEmpty || kept != attachments else { continue }
            result[index].attachments = kept.isEmpty ? nil : kept
            result[index].text = appendOmissions(to: messages[index].text, omissions)
        }

        return result
    }

    private static func costOf(
        _ attachment: Attachment,
        imageRawSizeOf: (String) -> Int
    ) -> Int {
        let inline = inlineCost(attachment)
        switch attachment.kind {
        case .image:
            if let inlined = attachment.base64Data, !inlined.isEmpty { return inline }
            guard let localImageID = attachment.localImageID else { return inline }
            return inline + base64Size(ofRawBytes: imageRawSizeOf(localImageID))
        case .video, .file:
            return inline
        }
    }

    private static func inlineCost(_ attachment: Attachment) -> Int {
        (attachment.base64Data?.utf8.count ?? 0)
            + (attachment.originalBase64Data?.utf8.count ?? 0)
            + (attachment.thumbnailBase64?.utf8.count ?? 0)
    }

    private static func base64Size(ofRawBytes rawBytes: Int) -> Int {
        guard rawBytes > 0 else { return 0 }
        return (rawBytes + 2) / 3 * 4
    }

    private static func lighten(_ attachment: Attachment) -> Attachment? {
        guard attachment.kind == .file else { return nil }
        guard let original = attachment.originalBase64Data, !original.isEmpty else { return nil }
        guard let extracted = attachment.base64Data, !extracted.isEmpty else { return nil }
        var lightened = attachment
        lightened.originalBase64Data = nil
        return lightened
    }

    private static func placeholder(for attachment: Attachment) -> String {
        let label: String
        switch attachment.kind {
        case .image: label = "Image"
        case .video: label = "Video"
        case .file: label = "File"
        }
        return "[\(label) omitted: \(attachment.fileName) "
            + "(older attachment dropped to keep this request small)]"
    }

    private static func appendOmissions(to text: String, _ omissions: [String]) -> String {
        guard !omissions.isEmpty else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? omissions : [text] + omissions).joined(separator: "\n\n")
    }
}
