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

    @Test("the General group uses list rows: Theme opens the theme page with a palette dot; Language and Backup share the group; the old Data and Appearance headers are gone")
    func generalGroupUsesListRows() throws {
        let source = try String(contentsOf: settingsViewSourceURL, encoding: .utf8)
        let general = try source.requiredSlice(
            from: "// MARK: - General",
            to: "// MARK: - Help & About"
        )
        let settingsRowSource = try String(contentsOf: settingsRowSourceURL, encoding: .utf8)
        let flatStyleSource = try String(contentsOf: flatSettingsStyleSourceURL, encoding: .utf8)

        #expect(general.contains("L10n.tr(\"General\", table: .settings)"))
        #expect(general.contains("value: themeRowSummary("))
        #expect(general.contains("showsPaletteDot: true"))
        #expect(general.contains("navigation.attemptNavigate(to: .themeSettings)"))
        #expect(general.contains("value: displayedLanguage.displayName"))
        #expect(general.contains("appState.openBackup()"))
        let theme = try #require(general.range(of: "key: \"theme\""))
        let language = try #require(general.range(of: "key: \"language\""))
        let backup = try #require(general.range(of: "key: \"backup\""))
        #expect(theme.upperBound < language.lowerBound && language.upperBound < backup.lowerBound)
        #expect(!general.contains("flatMenuRow"))
        #expect(!general.contains("Picker("))
        #expect(!general.contains("preferenceRow"))
        #expect(!source.contains("L10n.tr(\"Data\", table: .settings)"))
        #expect(!source.contains("L10n.tr(\"Appearance\", table: .settings)"))
        #expect(!source.contains("L10n.tr(\"About\", table: .settings)"))
        #expect(!source.contains("L10n.tr(\"Help & Feedback\", table: .settings)"))

        // The developer menu still uses SettingsRow and the flat style.
        #expect(settingsRowSource.contains(".font(OriveoTheme.Typography.caption)"))
        #expect(settingsRowSource.contains(".font(OriveoTheme.Typography.body)"))
        #expect(flatStyleSource.contains(".menuIndicator(.hidden)"))
        #expect(flatStyleSource.contains("func flatMenuRow"))
    }

    @Test("the AI group is a 2x2 grid: Memory, Context, Skills, Voice; the Voice tile opens the voice settings page and keeps the old row identifier")
    func aiGroupHasVoiceRowNavigatingToVoiceSettings() throws {
        let source = try String(contentsOf: settingsViewSourceURL, encoding: .utf8)
        let aiGroup = try source.requiredSlice(
            from: "// MARK: - AI",
            to: "// MARK: - Tools & connections"
        )
        let memory = try #require(aiGroup.range(of: "key: \"memory\""))
        let context = try #require(aiGroup.range(of: "key: \"context\""))
        let skills = try #require(aiGroup.range(of: "key: \"skills\""))
        let voice = try #require(aiGroup.range(of: "key: \"voice\""))

        #expect(memory.upperBound < context.lowerBound)
        #expect(context.upperBound < skills.lowerBound)
        #expect(skills.upperBound < voice.lowerBound)
        #expect(aiGroup.contains("SettingsHomeGrid(items:"))
        #expect(aiGroup.contains("legacyIdentifier: \"settings_voice_row\""))
        #expect(aiGroup.contains("legacyIdentifier: \"settings_context_row\""))
        #expect(aiGroup.contains("value: voiceEngineName"))
        #expect(aiGroup.contains("navigation.attemptNavigate(to: .voiceSettings)"))
        #expect(aiGroup.contains("title: L10n.tr(\"Voice\", table: .voice)"))
        #expect(source.contains("VoiceSettingsModel.engineDisplayName(for: VoiceEngineSettings().selection(for: .tts))"))
        #expect(NavigationManager.columnTab(for: .voiceSettings) == .settings)
    }

    @Test("Help & About is a 1x2 compact grid; the footer keeps the logo taps and the changelog")
    func helpGridAndFooterKeepExistingDestinations() throws {
        let source = try String(contentsOf: settingsViewSourceURL, encoding: .utf8)
        let help = try source.requiredSlice(
            from: "// MARK: - Help & About",
            to: "// MARK: - Footer"
        )
        #expect(help.contains("L10n.tr(\"Help & About\", table: .settings)"))
        #expect(help.contains("presentedWebDestination = .sourceCode"))
        #expect(help.contains("presentedWebDestination = .issues"))
        #expect(help.contains("style: .compact"))

        let footer = try source.requiredSlice(
            from: "private var settingsFooter: some View",
            to: "// MARK: - Helpers"
        )
        #expect(footer.contains("Button(action: handleAboutTap)"))
        #expect(footer.contains("presentedWebDestination = .releases"))
        #expect(source.contains(".background(alignment: .top) { SettingsHomeTopGlow() }"))
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

    private var oriveoSourcesRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Settings
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // OriveoTests
            .deletingLastPathComponent() // Oriveo project root
            .appendingPathComponent("Oriveo")
    }

    private var settingsViewSourceURL: URL {
        oriveoSourcesRootURL.appendingPathComponent("Features/Settings/SettingsView.swift")
    }

    private var settingsRowSourceURL: URL {
        oriveoSourcesRootURL.appendingPathComponent("Shared/Components/Rows/SettingsRow.swift")
    }

    private var flatSettingsStyleSourceURL: URL {
        oriveoSourcesRootURL.appendingPathComponent("Shared/Components/FlatSettingsStyle.swift")
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
