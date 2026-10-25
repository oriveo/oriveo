import Foundation

/// Locates a file under the repository's `shared/test-fixtures/` directory by walking up from this source file.
func sharedFixtureURL(_ relativePath: String) throws -> URL {
    var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while cursor.path != "/" {
        let candidate = cursor.appendingPathComponent("shared/test-fixtures/\(relativePath)")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        cursor.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
