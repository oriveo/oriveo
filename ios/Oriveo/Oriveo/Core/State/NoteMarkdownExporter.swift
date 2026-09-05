import Foundation

enum NoteMarkdownExporter {

    static func markdown(for note: Note) -> String {
        var parts: [String] = []
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append("# \(title.isEmpty ? L10n.tr("Untitled note", table: .notes) : title)")

        if let userNote = note.userNote?.trimmingCharacters(in: .whitespacesAndNewlines), !userNote.isEmpty {
            let quoted = userNote.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            parts.append(quoted)
        }

        if !note.tags.isEmpty {
            parts.append("Tags: \(note.tags.joined(separator: ", "))")
        }

        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            parts.append(body)
        }

        var sourceBlock: [String] = []
        if let sourceLine = sourceLine(for: note) {
            sourceBlock.append(sourceLine)
        }
        if let prompt = note.sourcePrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            sourceBlock.append("Prompt: \(prompt)")
        }
        if !sourceBlock.isEmpty {
            parts.append(sourceBlock.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n") + "\n"
    }

    private static func sourceLine(for note: Note) -> String? {
        guard note.captureKind != .blank else { return nil }
        let date = isoDate(note.createdAt)
        let segments = [note.sourceModelName, note.sourceProviderName, date].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        guard !segments.isEmpty else { return nil }
        if note.sourceModelName == nil && note.sourceProviderName == nil { return nil }
        return "Source: \(segments.joined(separator: " • "))"
    }

    private static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func filename(for note: Note) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = sanitize(title.isEmpty ? L10n.tr("Untitled note", table: .notes) : title)
        let date = isoDate(note.createdAt)
        if !date.isEmpty { name += "-\(date)" }
        return "\(name).md"
    }

    static func sanitize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "[/\\\\:*?\"<>|]+", with: "-", options: .regularExpression)
        s = s.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(s.prefix(80))
    }
}
