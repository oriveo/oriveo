import Foundation

enum NoteSourceResolver {

    static func previousUserPrompt(before messageID: UUID, in messages: [ChatMessage]) -> String? {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        for i in stride(from: idx - 1, through: 0, by: -1) {
            let m = messages[i]
            if m.role == .user {
                let trimmed = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return m.text }
            }
        }
        return nil
    }

}
