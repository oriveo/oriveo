import SwiftUI

/// Presentation policy for the hidden menu behind repeated taps on the About logo.
/// A confirmationDialog must not stack an alert or a fullScreenCover on top: on iOS 18+ the action
/// sheet's button actions get swallowed and the next presentation in the same transaction is dropped,
/// so choosing an option looks like nothing happened.
enum SettingsDeveloperMenuPolicy {
    static let logoTapRevealCount = 10

    enum SessionPage: Equatable {
        case menu
        case onboardingRehearsal
    }

    struct LogoTapResult: Equatable {
        var nextCount: Int
        var shouldRevealMenu: Bool
    }

    static func registerLogoTap(currentCount: Int) -> LogoTapResult {
        let nextCount = currentCount + 1
        if nextCount >= logoTapRevealCount {
            return LogoTapResult(nextCount: 0, shouldRevealMenu: true)
        }
        return LogoTapResult(nextCount: nextCount, shouldRevealMenu: false)
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.windowNavigation) private var windowNavigation
    /// This window's navigation state (one per window); a host without one injected (tests) falls back to the active window.
    private var navigation: NavigationManager { windowNavigation ?? appState.navigation }
    @State private var presentedWebDestination: ProjectWebDestination?
    @State private var aboutTapCount: Int = 0
    /// Revealed by tapping the About logo 10 times: shows the API host and replays the onboarding,
    /// which otherwise only appears once on first launch.
    @State private var showsDeveloperSession = false
    @State private var developerSessionPage: SettingsDeveloperMenuPolicy.SessionPage = .menu
    @State private var showsLanguageSettingsMigration: Bool = false
    /// Whether the catalog leaves remote MCP switched on, and the data for the row's subtitle.
    @State private var mcpEntryEnabled = MetadataClient.shared.syncMcpRuntimeConfig().enabled
    @State private var mcpEntrySummary: McpSettingsEntrySummary?
    /// Value of the Voice tile: the read-aloud engine name, re-read when coming back from the voice page.
    @State private var voiceEngineName: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.tr("Settings"))
                    .font(.system(size: 34, weight: .heavy))
                    .tracking(-34 * 0.03)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                // MARK: - AI
                VStack(alignment: .leading, spacing: 10) {
                    SettingsHomeSectionHeader(title: "AI")

                    SettingsHomeGrid(items: [
                        SettingsHomeGridItem(
                            key: "memory",
                            title: L10n.tr("Memory"),
                            value: memorySubtitle,
                            showsFeatureBadge: FeatureBadges.shared.isUnseen(FeatureBadges.settingsMemory),
                            action: { appState.openMemory() }
                        ),
                        SettingsHomeGridItem(
                            key: "context",
                            title: L10n.tr("settings_context_title", table: .settings),
                            value: ContextDefaultCapSetting.rowValue(in: appState),
                            legacyIdentifier: "settings_context_row",
                            action: { navigation.attemptNavigate(to: .contextSettings) }
                        ),
                        // Skills have no "enabled" notion (only pinned / source), so no value is shown.
                        SettingsHomeGridItem(
                            key: "skills",
                            title: L10n.tr("Skills"),
                            action: { appState.openSkillsList() }
                        ),
                        SettingsHomeGridItem(
                            key: "voice",
                            title: L10n.tr("Voice", table: .voice),
                            value: voiceEngineName,
                            legacyIdentifier: "settings_voice_row",
                            action: { navigation.attemptNavigate(to: .voiceSettings) }
                        ),
                    ])
                }
                .padding(.top, 20)

                // MARK: - Tools & connections
                // With the feature switched off in the catalog the entry is hidden; existing configuration is kept.
                if mcpEntryEnabled {
                    McpSettingsSection(
                        mcpSummary: mcpEntrySummary,
                        onOpenMcpServers: { navigation.attemptNavigate(to: .mcpServers) }
                    )
                    .padding(.top, 34)
                }

                // MARK: - General (theme, language, backup)
                VStack(alignment: .leading, spacing: 4) {
                    SettingsHomeSectionHeader(title: L10n.tr("General", table: .settings))

                    VStack(spacing: 0) {
                        SettingsHomeListRow(
                            key: "theme",
                            title: L10n.tr("Theme", table: .settings),
                            value: themeRowSummary(
                                theme: appState.preferences.theme,
                                darkPalette: appState.preferences.darkPalette
                            ),
                            showsPaletteDot: true,
                            action: { navigation.attemptNavigate(to: .themeSettings) }
                        )

                        SettingsHomeListRow(
                            key: "language",
                            title: L10n.tr("Language", table: .settings),
                            value: displayedLanguage.displayName,
                            action: { openLanguageSettings() }
                        )

                        SettingsHomeListRow(
                            key: "backup",
                            title: L10n.tr("Backup & Import/Export"),
                            isLast: true,
                            action: { appState.openBackup() }
                        )
                    }
                }
                .padding(.top, 34)

                // MARK: - Help & About
                VStack(alignment: .leading, spacing: 10) {
                    SettingsHomeSectionHeader(title: L10n.tr("Help & About", table: .settings))

                    SettingsHomeGrid(
                        items: [
                            SettingsHomeGridItem(
                                key: "faq",
                                title: L10n.tr("Source Code", table: .settings),
                                action: { presentedWebDestination = .sourceCode }
                            ),
                            SettingsHomeGridItem(
                                key: "feedback",
                                title: L10n.tr("Report an Issue", table: .settings),
                                action: { presentedWebDestination = .issues }
                            ),
                        ],
                        style: .compact
                    )
                }
                .padding(.top, 34)

                // MARK: - Footer (logo taps open the developer menu; name + version open the changelog)
                settingsFooter
                    .padding(.top, 38)
            }
            .padding(OriveoTheme.Spacing.xl)
            .padding(.bottom, OriveoTheme.Spacing.xxl)
            .oriveoContentWidth()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings_screen")
        // The dark top glow is attached only to the Settings home, on top of the shared background.
        .background(alignment: .top) { SettingsHomeTopGlow() }
        // The Settings home shows only its own top glow; the shared background's brand glow is not layered on.
        .oriveoScreenBackground(showsGlow: false)
        .id(appState.preferences.language)
        .onAppear {
            // Also when coming back from MCP management: the count in the subtitle has to follow.
            syncMcpEntry()
            // Also when coming back from the voice page: the read-aloud engine name has to follow.
            voiceEngineName = VoiceSettingsModel.engineDisplayName(for: VoiceEngineSettings().selection(for: .tts))
        }
        .task {
            await MetadataClient.shared.ensureInitialized()
            syncMcpEntry()
        }
        .sheet(item: $presentedWebDestination) { destination in
            OriveoSafariSheet(url: destination.url)
        }
        .alert(L10n.tr("Language", table: .settings), isPresented: $showsLanguageSettingsMigration) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Open iOS Settings", table: .settings)) {
                migrateToSystemLanguageAndOpenSettings()
            }
        } message: {
            Text(L10n.tr(
                "Choose Oriveo's language in iOS Settings so system menus use the same language.",
                table: .settings
            ))
        }
        .fullScreenCover(isPresented: $showsDeveloperSession) {
            developerSessionContent
        }
        .onChange(of: showsDeveloperSession) { _, isPresented in
            if !isPresented {
                developerSessionPage = .menu
            }
        }
    }

    @ViewBuilder
    private var developerSessionContent: some View {
        switch developerSessionPage {
        case .menu:
            SettingsDeveloperMenuView(
                endpointHost: BackendURLResolver.displayHost(),
                onReplayOnboarding: { developerSessionPage = .onboardingRehearsal },
                onClose: { showsDeveloperSession = false }
            )
        case .onboardingRehearsal:
            // Rehearsal mode: plays all four acts without writing hasCompletedOnboarding
            OnboardingFlowView(mode: .rehearsal) {
                showsDeveloperSession = false
            }
            .environment(appState)
        }
    }

    // MARK: - Footer

    private var settingsFooter: some View {
        VStack(spacing: 6) {
            Button(action: handleAboutTap) {
                Image("OriveoLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            Button {
                presentedWebDestination = .releases
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "Oriveo")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(verbatim: appVersion)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.tr("Changelog", table: .settings))
            .padding(.top, 4)

            Text(L10n.tr("All your models. One app.", table: .settings))
                .font(.system(size: 12))
                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                .padding(.top, 2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Helpers

    private var memorySubtitle: String {
        settingsMemoryPreview(appState.preferences.memoryText) ?? L10n.tr("Not set")
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "V\(version) (\(build))"
    }

    private var displayedLanguage: LanguageOption {
        AppLanguagePreferencePolicy.displayedLanguage(
            preference: appState.preferences.language,
            systemLanguage: .systemPreferred
        )
    }

    private func openLanguageSettings() {
        if appState.preferences.language == .system {
            openSystemAppSettings()
        } else {
            showsLanguageSettingsMigration = true
        }
    }

    /// Re-reads the MCP switch and the server overview (local storage only, no request).
    private func syncMcpEntry() {
        mcpEntryEnabled = MetadataClient.shared.syncMcpRuntimeConfig().enabled
        guard mcpEntryEnabled else { return }
        mcpEntrySummary = (try? appState.mcpServerDirectory.overview(uid: appState.sessionPartitionUID))
            .map { McpSettingsEntrySummary($0) }
    }

    private func migrateToSystemLanguageAndOpenSettings() {
        appState.migrateLanguagePreferenceToSystem()
        openSystemAppSettings()
    }

    private func openSystemAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func handleAboutTap() {
        let result = SettingsDeveloperMenuPolicy.registerLogoTap(currentCount: aboutTapCount)
        aboutTapCount = result.nextCount
        if result.shouldRevealMenu {
            developerSessionPage = .menu
            showsDeveloperSession = true
        }
    }
}

/// The menu page of the developer session: the host is written on the row itself, and replaying the
/// onboarding only swaps the content of the same cover.
struct SettingsDeveloperMenuView: View {
    let endpointHost: String
    let onReplayOnboarding: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.tr("Developer Options", table: .settings))
                    .font(OriveoTheme.Typography.title2)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                Spacer()
                Button(L10n.tr("Cancel"), action: onClose)
                    .font(OriveoTheme.Typography.body)
                    .foregroundStyle(OriveoTheme.Palette.primary)
            }
            .padding(.top, 24)

            flatGroup {
                SettingsRow(
                    icon: "globe",
                    title: L10n.tr("API Endpoint", table: .settings),
                    value: endpointHost,
                    iconColor: Color.dynamic(light: 0x3B82F6, dark: 0x60A5FA),
                    showsChevron: false
                )
                .padding(.horizontal, OriveoTheme.Spacing.lg)
                .padding(.vertical, 9)

                insetHairline()

                flatTapRow(action: onReplayOnboarding) {
                    SettingsRow(
                        icon: "sparkles",
                        title: L10n.tr("Replay Onboarding", table: .settings),
                        iconColor: Color.brand(light: \.ink, dark: \.primary)
                    )
                }
            }

            Spacer()
        }
        .padding(.horizontal, OriveoTheme.Spacing.xl)
        .oriveoScreenBackground()
    }
}

#Preview {
    SettingsView()
        .environment(AppState.preview)
}

/// Preview for the Memory tile on the Settings home: the first 30 characters, with "..." when longer; nil when empty (including a list marker only).
/// Memory is often stored as a Markdown list: leading list markers are removed and multiple lines are joined into one, so "- " does not show.
nonisolated func settingsMemoryPreview(_ text: String) -> String? {
    let flat = text.components(separatedBy: .newlines)
        .map { $0.replacingOccurrences(of: #"^\s*[-*•]\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard !flat.isEmpty else { return nil }
    let preview = String(flat.prefix(30))
    return flat.count > 30 ? preview + "..." : preview
}
