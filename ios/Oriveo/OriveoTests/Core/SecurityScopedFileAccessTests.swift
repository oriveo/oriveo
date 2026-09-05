import Foundation
import Testing
@testable import Oriveo

@Suite("SecurityScopedFileAccess")
struct SecurityScopedFileAccessTests {

    @Test("Local File URLRemains Readable")
    func localFileURLRemainsReadable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("# hello".utf8).write(to: url)

        let data = try SecurityScopedFileAccess.withAccess(to: url) {
            try Data(contentsOf: url)
        }

        #expect(String(data: data, encoding: .utf8) == "# hello")
    }
}
