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

}
