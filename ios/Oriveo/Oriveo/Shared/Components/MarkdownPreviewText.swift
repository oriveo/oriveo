import Foundation

/// Plain-text projection of markdown for one-line previews (conversation list rows and the
/// collapsed original-answer row in the second-opinion sheet).
/// Removes bold/italic, list markers, headings, quotes, inline code, links and code blocks,
/// then collapses whitespace to single spaces.
enum MarkdownPreviewText {
    static func plain(_ text: String) -> String {
        var result = text
        result = String(result.unicodeScalars.filter { scalar in
            scalar != "\u{FFFD}" && scalar != "\u{FFFC}" &&
            !(scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t") &&
            scalar.value != 0x7F
        })
        result = result.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "__(.+?)__", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<![\\*\\s])\\*([^\\*]+)\\*(?!\\*)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?<!_)_([^_]+)_(?!_)", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^>\\s?", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^[\\-\\*]\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(?m)^\\d+\\.\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }
}
