import CoreTransferable
import Foundation
import UniformTypeIdentifiers

enum ChatExport {
    static func markdown(
        summary: ConversationSummary,
        messages: [ChatMessage],
        timestampFormatter: DateFormatter = ChatExport.defaultTimestampFormatter()
    ) -> String {
        var lines: [String] = []
        let title = displayTitle(for: summary)
        lines.append("# \(title)")
        lines.append("")

        lines.append("*\(timestampFormatter.string(from: summary.updatedAt))*")
        lines.append("")

        for message in messages {
            let role = message.role == .user ? "User" : "Assistant"
            lines.append("## \(role)")
            lines.append("")
            lines.append(message.text)
            lines.append("")

            if message.role == .assistant, !message.modelName.isEmpty {
                let providerSuffix = message.providerName.isEmpty ? "" : " (\(message.providerName))"
                lines.append("*Model: \(message.modelName)\(providerSuffix)*")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func sanitizeFilename(_ raw: String) -> String {
        let invalid: Set<Character> = ["/", "\\", "?", "%", "*", ":", "|", "\"", "<", ">"]
        let mapped = raw.map { invalid.contains($0) ? "-" : $0 }
        let trimmed = String(mapped).trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "conversation" : trimmed
        return String(fallback.prefix(100))
    }

    static func displayTitle(for summary: ConversationSummary) -> String {
        let trimmed = summary.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : summary.title
    }

    static func defaultTimestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    static func writeMarkdownTempFile(
        summary: ConversationSummary,
        messages: [ChatMessage]
    ) throws -> URL {
        let markdown = self.markdown(summary: summary, messages: messages)
        let filename = sanitizeFilename(displayTitle(for: summary))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(filename).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct ChatMarkdownDocument: Transferable {
    let filename: String
    let markdown: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { document in
            Data(document.markdown.utf8)
        }
        .suggestedFileName { "\($0.filename).md" }
    }
}
