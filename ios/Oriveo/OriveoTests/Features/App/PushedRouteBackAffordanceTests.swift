import Foundation
import Testing
@testable import Oriveo

/// Every destination is wrapped in `oriveoNavigationChrome()`, which hides the native
/// navigation bar **along with the system back button**, so each pushed full-screen page has to
/// place its own way back. Miss one and the only exit left on that page is the left-edge swipe:
/// findable on a phone, effectively no exit at all on a wide screen.
///
/// `NotesView` was the one that missed it — `NoteDetailView`'s comment even says "following
/// NotesView.header", having copied the in-body header idea without the back button, because
/// the page it followed never had one.
///
/// This scans source rather than rendering: the back button is a `Button { pop() }`, which a
/// view snapshot cannot assert on.
@Suite("PushedRouteBackAffordance")
struct PushedRouteBackAffordanceTests {

    /// One entry per pushed destination. Add new routes here; a missing entry is a missing gate.
    private static let pushedScreens = [
        "Features/Notes/NotesView.swift",
        "Features/Notes/NoteDetailView.swift",
        "Features/Home/FolderDetailView.swift",
        "Features/Settings/MemoryView.swift",
        "Features/Skills/SkillsListView.swift",
        "Features/Skills/SkillEditView.swift",
        "Features/Backup/BackupView.swift",
        "Features/Providers/ProviderDetailView.swift",
        "Features/Providers/ProviderSetupView.swift",
        "Features/Providers/ManualModelEntryView.swift",
        "Features/Providers/RelaySetupView.swift",
    ]

    @Test("Every pushed full-screen page places its own way back")
    func everyPushedScreenCanGoBack() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Features/App
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // OriveoTests
            .deletingLastPathComponent()   // Oriveo
            .appendingPathComponent("Oriveo")

        var missing: [String] = []
        for screen in Self.pushedScreens {
            let source = try String(contentsOf: root.appendingPathComponent(screen), encoding: .utf8)
            let canGoBack = source.contains("appState.pop()")
                || source.contains("navigation.pop()")
                || source.contains("dismiss()")
            if !canGoBack { missing.append(screen) }
        }

        #expect(missing.isEmpty, "these pushed pages offer no way back: \(missing.joined(separator: ", "))")
    }
}
