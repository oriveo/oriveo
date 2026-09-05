import Foundation
import Testing

@Suite("ProviderSetupStatusPlacement")
struct ProviderSetupStatusPlacementTests {

    @Test("Syncing Status Banner Appears Before Scrollable Content")
    func syncingStatusBannerAppearsBeforeScrollableContent() throws {
        let source = try String(contentsOf: providerSetupSourceURL(), encoding: .utf8)
        let bannerRange = try #require(source.range(of: "providerSetupSyncingStatusBanner(text: inlineStatusText)"))
        let scrollRange = try #require(source.range(of: "ScrollView {"))

        #expect(bannerRange.lowerBound < scrollRange.lowerBound)
    }

    private func providerSetupSourceURL() -> URL {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return projectDirectory
            .appendingPathComponent("Oriveo")
            .appendingPathComponent("Features")
            .appendingPathComponent("Providers")
            .appendingPathComponent("ProviderSetupView.swift")
    }
}
