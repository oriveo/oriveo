import Foundation

// Walks up from #filePath to find `shared/context-contracts/<name>` under the repository root, so every platform reads the same fixture.
enum ContextContractFixture {
    static func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    /// Raw fixture bytes; used with JSONSerialization when the field shape is not fixed (for example the overflow body may be an object or a string).
    static func data(_ name: String) throws -> Data {
        var folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while folder.path != "/" {
            let candidate = folder
                .appendingPathComponent("shared")
                .appendingPathComponent("context-contracts")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
            folder.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Comparison tolerance for rho / rhoHi: absolute error 1e-12.
    static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= 1e-12
    }
}
