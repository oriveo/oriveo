import SwiftUI

struct BackupView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        #if DEBUG
        let _ = Self._printChanges()
        #endif
        ScrollView {
            VStack(alignment: .leading, spacing: OriveoTheme.Spacing.xl) {
                topBar
                BackupExportSection()
                BackupImportSection()
            }
            .padding(OriveoTheme.Spacing.xl)
            .padding(.bottom, OriveoTheme.Spacing.xxl)
            .oriveoContentWidth()
        }
        .oriveoScreenBackground()
    }


    private var topBar: some View {
        HStack {
            OriveoBackButton {
                appState.pop()
            }
            .padding(.leading, -OriveoBackButton.edgeInset)

            Spacer()

            Text(L10n.tr("Backup & Import/Export"))
                .font(OriveoTheme.Typography.title3)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)

            Spacer()

            Color.clear
                .frame(width: OriveoBackButton.hitSize - OriveoBackButton.edgeInset, height: 32)
        }
    }
}

#Preview {
    BackupView()
        .environment(AppState.preview)
}
