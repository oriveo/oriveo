import Foundation
import Testing
@testable import Oriveo

@Suite("SettingsView")
@MainActor
struct SettingsViewTests {
    @Test("Backend Display Host Extracts Host And Port")
    func backendDisplayHostExtractsHostAndPort() {
        #expect(BackendURLResolver.displayHost(for: "https://example.com/v1") == "example.com")
        #expect(BackendURLResolver.displayHost(for: "http://localhost:8080/metadata") == "localhost:8080")
        #expect(BackendURLResolver.displayHost(for: "oriveo.internal/path") == "oriveo.internal")
    }

    @Test("Language Entry Uses System App Settings")
    func languageEntryUsesSystemAppSettings() throws {
        let source = try String(contentsOf: settingsViewSourceURL, encoding: .utf8)

        #expect(source.contains("UIApplication.openSettingsURLString"))
        #expect(source.contains("appState.migrateLanguagePreferenceToSystem()"))
        #expect(!source.contains("Picker(L10n.tr(\"Language\""))
    }

    private var settingsViewSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Settings
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo project root
            .appendingPathComponent("Oriveo/Features/Settings/SettingsView.swift")
    }
}
