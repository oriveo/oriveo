import SwiftUI

/// Row model for the recognition language form: the option list is shared with the settings page, the current item is checked;
/// tapping an item writes the setting and reports whether it changed.
struct RecognitionLanguageSheetModel {
    struct Row: Identifiable, Equatable {
        let option: VoiceRecognitionLanguageOption
        let isSelected: Bool
        var id: String { option.id }
    }

    let current: String?
    let settings: VoiceEngineSettings

    init(current: String?, settings: VoiceEngineSettings = VoiceEngineSettings()) {
        self.current = current
        self.settings = settings
    }

    var rows: [Row] {
        VoiceSettingsModel.recognitionLanguageOptions().map { Row(option: $0, isSelected: $0.code == current) }
    }

    /// Selects an item: writes the setting only if it differs from the current value; returns whether it changed.
    func select(_ code: String?) -> Bool {
        guard code != current else { return false }
        settings.recognitionLanguage = code
        return true
    }

    /// Language name: same lookup as the "Recognition Language" row on the settings page (option title; nil = automatic).
    /// For a region code not in the option list (e.g. en-US), use the system language name in the UI locale with the first letter capitalized
    /// (same as Android recognitionLanguageDisplayName); fall back to the raw code only if the system cannot resolve it either.
    static func displayName(_ code: String?) -> String {
        guard let code else { return L10n.tr("Automatic", table: .voice) }
        if let title = VoiceSettingsModel.recognitionLanguageOptions().first(where: { $0.code == code })?.title {
            return title
        }
        return systemLanguageName(code, locale: AppLocalization.currentLocale) ?? code
    }

    /// System language name: nil when the system does not recognize the language part (do not fabricate a combined name).
    private static func systemLanguageName(_ code: String, locale: Locale) -> String? {
        guard let language = Locale(identifier: code).language.languageCode?.identifier,
              locale.localizedString(forLanguageCode: language) != nil,
              let name = locale.localizedString(forIdentifier: code), !name.isEmpty
        else { return nil }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}

/// Changes the recognition language from the voice stage: a half-height form; tapping an item writes the setting and closes it.
/// The next utterance in the conversation is recognized in the new language.
/// Closing (including without a change or dismissing by swipe) calls onDone exactly once.
struct RecognitionLanguageSheet: View {
    let current: String?
    var settings = VoiceEngineSettings()
    let onDone: (_ changed: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reported = false

    private var model: RecognitionLanguageSheetModel {
        RecognitionLanguageSheetModel(current: current, settings: settings)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.rows) { row in
                    Button {
                        report(model.select(row.option.code))
                        dismiss()
                    } label: {
                        HStack {
                            Text(row.option.title)
                                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            Spacer()
                            if row.isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(row.isSelected ? .isSelected : [])
                }
            }
            .navigationTitle(L10n.tr("Recognition Language", table: .voice))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { report(false) }
    }

    private func report(_ changed: Bool) {
        guard !reported else { return }
        reported = true
        onDone(changed)
    }
}

extension VoiceLanguageChip {
    /// Recognition language chip on the stage: shows the current setting's name; a tap pauses listening before opening the form.
    @MainActor
    static func recognitionLanguage(
        session: VoiceConversationSession = .shared, open: @escaping () -> Void
    ) -> VoiceLanguageChip {
        VoiceLanguageChip(
            name: RecognitionLanguageSheetModel.displayName(VoiceEngineSettings().recognitionLanguage),
            action: {
                session.setLanguagePickerOpen(true)
                open()
            }
        )
    }
}

extension View {
    /// Attaches the recognition language form; listening resumes when the form closes (whether or not it changed).
    /// If the host disappears, the form is torn down and onDismiss may not fire; listening resumes in that case too.
    func recognitionLanguageSheet(
        isPresented: Binding<Bool>, session: VoiceConversationSession = .shared
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: { session.setLanguagePickerOpen(false) }) {
            RecognitionLanguageSheet(current: VoiceEngineSettings().recognitionLanguage) { _ in
                isPresented.wrappedValue = false
            }
        }
        .onDisappear { session.setLanguagePickerOpen(false) }
    }
}
