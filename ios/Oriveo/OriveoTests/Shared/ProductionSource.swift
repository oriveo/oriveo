import Foundation

/// Path entry point for structural assertions that read production sources (relative to `ios/Oriveo/Oriveo`).
enum ProductionSource {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Shared
        .deletingLastPathComponent()   // OriveoTests
        .deletingLastPathComponent()   // Oriveo (project dir)
        .appendingPathComponent("Oriveo", isDirectory: true)

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The per-language values of one key in `<table>.xcstrings` (language code -> text).
    static func localizations(table: String, key: String) throws -> [String: String] {
        let data = try Data(contentsOf: root.appendingPathComponent("\(table).xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = json?["strings"] as? [String: Any]
        let entry = strings?[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any] ?? [:]
        var result: [String: String] = [:]
        for (language, value) in localizations {
            let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any]
            if let text = unit?["value"] as? String { result[language] = text }
        }
        return result
    }
}
