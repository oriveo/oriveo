import Foundation
@testable import Oriveo

/// Loader for the shared fixtures in `shared/test-fixtures/mcp/`. Every client runs against the same files,
/// so adding a file to that directory amounts to changing the contract.
enum McpFixture {
    /// Walks up from this test file until it finds `shared/test-fixtures/mcp/<name>` in the repository.
    static func url(_ name: String) throws -> URL {
        var cursor = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while cursor.path != "/" {
            let candidate = cursor
                .appendingPathComponent("shared")
                .appendingPathComponent("test-fixtures")
                .appendingPathComponent("mcp")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            cursor.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONValue(data: Data(contentsOf: url(name)))
    }
}
