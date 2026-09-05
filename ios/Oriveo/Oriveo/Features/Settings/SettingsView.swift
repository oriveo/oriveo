import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var presentedWebDestination: ProjectWebDestination?
    @State private var aboutTapCount: Int = 0
    @State private var showsDeveloperMenu: Bool = false
    @State private var showsAPIEndpoint: Bool = false
    @State private var showsLanguageSettingsMigration: Bool = false
    @State private var showsOnboardingRehearsal: Bool = false

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
        .confirmationDialog(
            L10n.tr("Developer Options", table: .settings),
            isPresented: $showsDeveloperMenu,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("API Endpoint", table: .settings)) { showsAPIEndpoint = true }
            Button(L10n.tr("Replay Onboarding", table: .settings)) { showsOnboardingRehearsal = true }
            Button(L10n.tr("Cancel"), role: .cancel) {}
        }
        .alert(L10n.tr("API Endpoint", table: .settings), isPresented: $showsAPIEndpoint) {
            Button(L10n.tr("OK"), role: .cancel) {}
        } message: {
            Text(BackendURLResolver.displayHost())
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
        .fullScreenCover(isPresented: $showsOnboardingRehearsal) {
            OnboardingFlowView(mode: .rehearsal) {
                showsOnboardingRehearsal = false
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
        aboutTapCount += 1
        if aboutTapCount >= 10 {
            aboutTapCount = 0
            showsDeveloperMenu = true
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

#Preview {
    SettingsView()
        .environment(AppState.preview)
}
