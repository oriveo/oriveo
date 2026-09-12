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

    @Test("the About logo reveals the developer menu on the tenth tap and resets the count")
    func aboutLogoRevealsDeveloperMenuOnTenthTap() {
        var count = 0
        for _ in 1...9 {
            let result = SettingsDeveloperMenuPolicy.registerLogoTap(currentCount: count)
            #expect(!result.shouldRevealMenu)
            count = result.nextCount
        }
        #expect(count == 9)

        let tenth = SettingsDeveloperMenuPolicy.registerLogoTap(currentCount: count)
        #expect(tenth.shouldRevealMenu)
        #expect(tenth.nextCount == 0)
    }

    @Test("the developer entry opens one session directly, without a confirmationDialog handoff")
    func developerSessionOpensWithoutConfirmationDialogHandoff() throws {
        let source = try String(contentsOf: settingsViewSourceURL, encoding: .utf8)

        #expect(!source.contains(".confirmationDialog("))
        #expect(source.contains("showsDeveloperSession = true"))
        #expect(source.contains(".fullScreenCover(isPresented: $showsDeveloperSession)"))
        #expect(source.contains("developerSessionPage = .onboardingRehearsal"))
        #expect(source.contains("SettingsDeveloperMenuView("))
        #expect(source.contains("endpointHost: BackendURLResolver.displayHost()"))
        #expect(!source.contains("queueDeveloperOverlay"))
        #expect(!source.contains("overlayHandoffDelay"))
    }

    @Test("the developer menu shows the host inline and replays onboarding in the same cover")
    func developerMenuShowsHostInlineAndReplaysInSameCover() throws {
        let source = try String(contentsOf: settingsViewSourceURL, encoding: .utf8)
        let menu = try source.requiredSlice(
            from: "struct SettingsDeveloperMenuView: View",
            to: "#Preview"
        )
        let session = try source.requiredSlice(
            from: "private var developerSessionContent",
            to: "// MARK: - Helpers"
        )

        #expect(menu.contains("endpointHost"))
        #expect(menu.contains("L10n.tr(\"API Endpoint\""))
        #expect(menu.contains("showsChevron: false"))
        #expect(menu.contains("onReplayOnboarding"))
        #expect(session.contains("case .onboardingRehearsal:"))
        #expect(session.contains("OnboardingFlowView(mode: .rehearsal)"))
        #expect(!session.contains(".alert("))
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

private extension String {
    func requiredSlice(from start: String, to end: String) throws -> String {
        guard let startRange = range(of: start),
              let endRange = range(of: end, range: startRange.upperBound..<endIndex) else {
            throw SettingsViewSourceSliceError.missingBoundary
        }
        return String(self[startRange.lowerBound..<endRange.lowerBound])
    }
}

private enum SettingsViewSourceSliceError: Error {
    case missingBoundary
}
