import Foundation

/// Input transcription language hint, mirroring scripts/lib/realtime-events.mjs:transcriptionLanguage.
/// Maps the host recognition language BCP-47 tag to each transport's wire value; nil = do not send.
/// OpenAI sends only the two-letter primary language; xAI es / pt must include a region, others send the primary language;
/// Gemini sends zh-Hans / zh-Hant for Chinese, otherwise the primary language plus region. Three-letter primary languages, empty and malformed tags are not sent.
nonisolated enum RealtimeTranscriptionLanguage {
    private static let legacy: [String: String] = ["in": "id", "iw": "he", "ji": "yi"]

    static func transcriptionLanguage(transport: RealtimeTransportKind, tag: String?) -> String? {
        guard let tag else { return nil }
        let parts = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: "-")
        let primary = parts[0].lowercased()
        guard isASCIILetters(primary, count: 2) else { return nil }
        let lang = legacy[primary] ?? primary
        var index = 1
        var script: String?
        if index < parts.count, isASCIILetters(parts[index], count: 4) {
            script = parts[index].lowercased()
            index += 1
        }
        var region: String?
        if index < parts.count {
            let part = parts[index]
            if isASCIILetters(part, count: 2) || isASCIIDigits(part, count: 3) { region = part.uppercased() }
        }
        switch transport {
        case .openaiRealtime:
            return lang
        case .xaiRealtime:
            if lang == "es" || lang == "pt" { return region.map { "\(lang)-\($0)" } }
            return lang
        case .geminiLive:
            if lang == "zh" {
                let hant = script == "hant" || (script == nil && ["TW", "HK", "MO"].contains(region ?? ""))
                return hant ? "zh-Hant" : "zh-Hans"
            }
            return region.map { "\(lang)-\($0)" } ?? lang
        }
    }

    private static func isASCIILetters(_ text: String, count: Int) -> Bool {
        text.unicodeScalars.count == count
            && text.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
    }

    private static func isASCIIDigits(_ text: String, count: Int) -> Bool {
        text.unicodeScalars.count == count && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }
}
