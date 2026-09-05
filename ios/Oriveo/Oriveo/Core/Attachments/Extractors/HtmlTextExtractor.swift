import Foundation

enum HtmlTextExtractor {
    static func extract(data: Data) throws -> String {
        var html: String
        if let s = String(data: data, encoding: .utf8) {
            html = s
        } else if let s = String(data: data, encoding: .isoLatin1) {
            html = s
        } else {
            throw ExtractionError(code: .corruptedFile)
        }

        html = html.replacingOccurrences(
            of: #"<script[\s\S]*?</script>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        html = html.replacingOccurrences(
            of: #"<style[\s\S]*?</style>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        html = html.replacingOccurrences(
            of: #"<noscript[\s\S]*?</noscript>"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        html = html.replacingOccurrences(
            of: #"</?(p|div|h[1-6]|li|tr|br|hr)[^>]*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        html = html.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )

        html = html.replacingOccurrences(of: "&nbsp;", with: " ")
                   .replacingOccurrences(of: "&amp;", with: "&")
                   .replacingOccurrences(of: "&lt;", with: "<")
                   .replacingOccurrences(of: "&gt;", with: ">")
                   .replacingOccurrences(of: "&quot;", with: "\"")
                   .replacingOccurrences(of: "&#39;", with: "'")
                   .replacingOccurrences(of: "&apos;", with: "'")

        html = html.replacingOccurrences(
            of: #"&#(\d+);"#,
            with: "",
            options: .regularExpression
        )

        html = html.replacingOccurrences(
            of: "[ \t]+",
            with: " ",
            options: .regularExpression
        )
        html = html.replacingOccurrences(
            of: #"\n\s*\n\s*\n+"#,
            with: "\n\n",
            options: .regularExpression
        )

        return html.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
