import Testing
@testable import Oriveo

@Suite("Backup navigation")
@MainActor
struct BackupNavigationTests {
    @Test("Open Backup Pushes Backup Route")
    func openBackupPushesBackupRoute() {
        let appState = AppState(seedDemoData: true)

        appState.openBackup()

        #expect(appState.navigation.path.last == .backup)
    }
}
