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
    @State private var presentedWebDestination: ProjectWebDestination?
    @State private var aboutTapCount: Int = 0
    /// Revealed by tapping the About logo 10 times: shows the API host and replays the onboarding,
    /// which otherwise only appears once on first launch.
    @State private var showsDeveloperSession = false
    @State private var developerSessionPage: SettingsDeveloperMenuPolicy.SessionPage = .menu
    @State private var showsLanguageSettingsMigration: Bool = false
    private let aiColor = Color.dynamic(light: 0x8C5FF8, dark: 0xA78BFA)
    private let dataColor = Color.dynamic(light: 0x3B82F6, dark: 0x60A5FA)
    private let appearanceColor = OriveoTheme.Palette.warning
    private let feedbackColor = Color.dynamic(light: 0x0EA5E9, dark: 0x38BDF8)
    private let faqColor = Color.dynamic(light: 0x6366F1, dark: 0xA5B4FC)
    private let ratingColor = Color.dynamic(light: 0xF59E0B, dark: 0xFBBF24)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.tr("Settings"))
                    .font(OriveoTheme.Typography.title1)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)

                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                    flatSectionHeader("AI")

                    flatGroup {
                        flatTapRow {
                            appState.openMemory()
                        } label: {
                            SettingsRow(
                                icon: "brain",
                                title: L10n.tr("Memory"),
                                value: memorySubtitle,
                                iconColor: aiColor
                            )
                        }

                        insetHairline()

                        flatTapRow {
                            appState.openSkillsList()
                        } label: {
                            SettingsRow(
                                icon: "lightbulb.fill",
                                title: L10n.tr("Skills"),
                                iconColor: aiColor
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                    flatSectionHeader(L10n.tr("Data", table: .settings))

                    flatGroup {
                        flatTapRow {
                            appState.openBackup()
                        } label: {
                            SettingsRow(
                                icon: "icloud.and.arrow.up",
                                title: L10n.tr("Backup & Import/Export"),
                                iconColor: dataColor
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                    flatSectionHeader(L10n.tr("Appearance", table: .settings))

                    flatGroup {
                        preferenceRow(
                            icon: "circle.lefthalf.filled",
                            iconColor: appearanceColor,
                            title: L10n.tr("Theme", table: .settings)
                        ) {
                            Picker(L10n.tr("Theme", table: .settings), selection: Binding(
                                get: { appState.preferences.theme },
                                set: { appState.updateTheme($0) }
                            )) {
                                ForEach(ThemeOption.allCases) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(OriveoTheme.Palette.textSecondary)
                        }

                        insetHairline()

                        flatTapRow {
                            openLanguageSettings()
                        } label: {
                            SettingsRow(
                                icon: "globe",
                                title: L10n.tr("Language", table: .settings),
                                value: displayedLanguage.displayName,
                                iconColor: appearanceColor
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                    flatSectionHeader(L10n.tr("Help & Feedback", table: .settings))

                    flatGroup {
                        flatTapRow {
                            presentedWebDestination = .sourceCode
                        } label: {
                            SettingsRow(
                                icon: "chevron.left.forwardslash.chevron.right",
                                title: L10n.tr("Source Code", table: .settings),
                                iconColor: faqColor
                            )
                        }

                        insetHairline()

                        flatTapRow {
                            presentedWebDestination = .issues
                        } label: {
                            SettingsRow(
                                icon: "exclamationmark.bubble.fill",
                                title: L10n.tr("Report an Issue", table: .settings),
                                iconColor: feedbackColor
                            )
                        }
                    }
                }


                VStack(alignment: .leading, spacing: OriveoTheme.Spacing.sm) {
                    flatSectionHeader(L10n.tr("About", table: .settings))

                    flatGroup {
                        HStack(spacing: OriveoTheme.Spacing.md) {
                            Button(action: handleAboutTap) {
                                Image("OriveoLogo")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHidden(true)

                            Button {
                                presentedWebDestination = .releases
                            } label: {
                                HStack(spacing: OriveoTheme.Spacing.md) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Oriveo")
                                            .font(OriveoTheme.Typography.title3)
                                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                                        Text(L10n.tr("All your models. One app.", table: .settings))
                                            .font(OriveoTheme.Typography.caption)
                                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                                        Text(appVersion)
                                            .font(OriveoTheme.Typography.footnote)
                                            .foregroundStyle(OriveoTheme.Palette.textTertiary)
                                    }

                                    Spacer(minLength: 0)

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                                }
                                .contentShape(Rectangle())
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.tr("Changelog", table: .settings))
                        }
                        .padding(OriveoTheme.Spacing.lg)
                    }

                }
            }
            .padding(OriveoTheme.Spacing.xl)
            .padding(.bottom, OriveoTheme.Spacing.xxl)
        }
        .oriveoScreenBackground()
        .id(appState.preferences.language)
        .task {
            await MetadataClient.shared.ensureInitialized()
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

    // MARK: - Helpers

    private var memorySubtitle: String {
        let text = appState.preferences.memoryText
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.tr("Not set")
        }
        let preview = String(text.prefix(30))
        return text.count > 30 ? preview + "..." : preview
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

    private func preferenceRow<Content: View>(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: OriveoTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconColor)
                )

            Text(title)
                .font(OriveoTheme.Typography.body)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            Spacer()

            content()
        }
        .padding(.horizontal, OriveoTheme.Spacing.lg)
        .padding(.vertical, 14)
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
                        iconColor: Color.dynamic(light: 0x8C5FF8, dark: 0xA78BFA)
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
