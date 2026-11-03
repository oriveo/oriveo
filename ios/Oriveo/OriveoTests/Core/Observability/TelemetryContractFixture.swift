import Foundation
@testable import Oriveo

/// Shared fixture `shared/observability-contracts/mobile-telemetry.v1.json`: the single source of truth for observability naming on both platforms.
/// Tests read the file in the repository directly (the simulator test host can reach host paths) instead of copying it into test resources, so the copies cannot drift.
enum TelemetryContractFixture {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Observability
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo (project dir)
            .deletingLastPathComponent()   // ios
            .deletingLastPathComponent()   // repo root
    }

    static var appSourceRoot: URL {
        repositoryRoot.appendingPathComponent("ios/Oriveo/Oriveo")
    }

    static func load() throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent("shared/observability-contracts/mobile-telemetry.v1.json")
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return json
    }
}
