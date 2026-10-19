import Foundation

// Outbound history normalization. The spec is unansweredEnvelope.rules in `shared/context-contracts/sanitize.v1.json`;
// the algorithm is adapted onto ContextMessage from the app request builder's filteredMessages / mergeAdjacentSameRole /
// mergeUserRun / escapeUnansweredXML, and the app's original functions are left untouched.

public enum ContextSanitizer {
    public static let unansweredTag = "oriveo-unanswered"
    /// Identical verbatim on all platforms; changes must stay in sync with the contract.
    public static let unansweredNote =
        "The user sent this earlier but no reply was delivered. Treat it as context and answer the latest message."

    /// Filter + merge adjacent messages of the same role. `keepAssistantId` is the continue / retry target, kept as a prefill according to delivered.
    public static func sanitize(_ messages: [ContextMessage], keepAssistantId: String? = nil) -> [ContextMessage] {
        sanitizeCounting(messages, keepAssistantId: keepAssistantId).messages
    }

    /// Same as sanitize, and also returns how many earlier user messages were merged into the following user message (the manifest's unansweredMerged).
    static func sanitizeCounting(
        _ messages: [ContextMessage],
        keepAssistantId: String?
    ) -> (messages: [ContextMessage], unansweredMerged: Int) {
        mergeAdjacentSameRole(filtered(messages, keepAssistantId: keepAssistantId))
    }

    /// Unicode White_Space property set (identical on all platforms): U+0009-000D, 0020, 0085,
    /// 00A0, 1680, 2000-200A, 2028, 2029, 202F, 205F, 3000. U+FEFF and U+001C-001F do not count as whitespace.
    static let unicodeWhiteSpace: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: Unicode.Scalar(0x0009)! ... Unicode.Scalar(0x000D)!)
        set.insert(charactersIn: Unicode.Scalar(0x2000)! ... Unicode.Scalar(0x200A)!)
        for value: UInt32 in [0x0020, 0x0085, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000] {
            set.insert(Unicode.Scalar(value)!)
        }
        return set
    }()

    /// The single trim definition for everything in this directory; `.whitespacesAndNewlines` is not used because its members depend on the Foundation version.
    static func trimWhiteSpace(_ text: String) -> String {
        text.trimmingCharacters(in: unicodeWhiteSpace)
    }

    static func trimmed(_ text: String) -> String {
        trimWhiteSpace(text)
    }

    /// & must be replaced first, otherwise the entities produced by later replacements would be escaped a second time.
    static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func filtered(_ messages: [ContextMessage], keepAssistantId: String?) -> [ContextMessage] {
        messages.compactMap { message in
            var result = message
            if let keepAssistantId, result.id == keepAssistantId {
                result.state = .delivered
            }
            // An assistant message must not carry image / video content (the OpenAI-compatible protocol only allows it on user), so it is stripped on the way out;
            // an assistant message left with neither text nor attachments after stripping is removed entirely below.
            if result.role == .assistant {
                result.attachments.removeAll { $0.kind == .image || $0.kind == .video }
            }
            guard !trimmed(result.text).isEmpty || !result.attachments.isEmpty else {
                return nil
            }
            // Keep every user message; for assistant drop only failed ones (a failed turn is not context, and the error text in its placeholder must not be sent back as an answer).
            if result.role == .user || result.state != .failed {
                return result
            }
            return nil
        }
    }

    /// Adjacent user messages are merged into one carrying an <oriveo-unanswered> envelope; adjacent assistant texts are joined with a blank line and their attachments merged in order.
    private static func mergeAdjacentSameRole(
        _ messages: [ContextMessage]
    ) -> (messages: [ContextMessage], unansweredMerged: Int) {
        var merged: [ContextMessage] = []
        var userRun: [ContextMessage] = []
        var unansweredMerged = 0
        func flushUserRun() {
            guard !userRun.isEmpty else { return }
            unansweredMerged += userRun.count - 1
            merged.append(mergeUserRun(userRun))
            userRun.removeAll()
        }
        for message in messages {
            if message.role == .user {
                userRun.append(message)
                continue
            }
            flushUserRun()
            if let last = merged.last, last.role == message.role {
                var combined = last
                combined.text = [trimmed(last.text), trimmed(message.text)]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                combined.attachments = last.attachments + message.attachments
                merged[merged.count - 1] = combined
            } else {
                merged.append(message)
            }
        }
        flushUserRun()
        return (merged, unansweredMerged)
    }

    private static func mergeUserRun(_ run: [ContextMessage]) -> ContextMessage {
        guard var result = run.last else {
            preconditionFailure("mergeUserRun requires a non-empty run")
        }
        guard run.count >= 2 else { return result }
        let earlierTexts = run.dropLast()
            .map { trimmed($0.text) }
            .filter { !$0.isEmpty }
            .map(escapeXML)
        if !earlierTexts.isEmpty {
            let envelope = "<\(unansweredTag)>\n<note>\(unansweredNote)</note>\n"
                + earlierTexts.joined(separator: "\n\n")
                + "\n</\(unansweredTag)>"
            // "The last one is empty" means only the empty string (not trimmed), the same definition as an empty plan body.
            result.text = result.text.isEmpty ? envelope : envelope + "\n\n" + result.text
        }
        result.attachments = run.flatMap(\.attachments)
        return result
    }
}
