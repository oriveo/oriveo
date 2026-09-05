import Foundation
import Testing
@testable import Oriveo

@Suite("AppState memory usage bookkeeping", .serialized)
@MainActor
struct AppStateMemoryUsageTests {

    private func withActiveUID<T>(_ uid: String, _ action: () throws -> T) rethrows -> T {
        let savedUID = AppSessionStore.activeUID
        AppSessionStore.switchToUser(uid)
        defer { AppSessionStore.switchToUser(savedUID) }
        return try action()
    }

    private func clearMemoryKeys(for uid: String) {
        AppPreferencesStore.clearAccountData(for: uid)
    }

    @Test("markMemoryUsedIfNeeded deduplicates conversation usage")
    func markMemoryUsedOncePerConversation() {
        let uid = "appstate-usage-\(UUID().uuidString.prefix(8))"
        withActiveUID(uid) {
            clearMemoryKeys(for: uid)

            let state = AppState(seedDemoData: true)
            let firstID = UUID()
            let secondID = UUID()

            state.markMemoryUsedIfNeeded(in: firstID)
            state.markMemoryUsedIfNeeded(in: firstID)
            state.markMemoryUsedIfNeeded(in: secondID)

            #expect(state.memoryUsageCount == 2)
            #expect(state.memoryUsageConversationIDs.contains(firstID))
            #expect(state.memoryUsageConversationIDs.contains(secondID))
            #expect(AppPreferencesStore.memoryUsageCount == 2)
            #expect(Set(AppPreferencesStore.memoryUsageConversationIDs) == Set(state.memoryUsageConversationIDs.map { $0.uuidString }))

            clearMemoryKeys(for: uid)
        }
    }

    @Test("loadMemoryUsageData reads persisted preferences back into state")
    func loadMemoryUsageDataRestoresCounts() {
        let uid = "appstate-usage-restore-\(UUID().uuidString.prefix(8))"
        withActiveUID(uid) {
            clearMemoryKeys(for: uid)
            let convIDs = [UUID(), UUID()]
            AppPreferencesStore.memoryUsageCount = convIDs.count
            AppPreferencesStore.memoryUsageConversationIDs = convIDs.map { $0.uuidString }

            let state = AppState(seedDemoData: true)
            state.memoryUsageCount = 0
            state.memoryUsageConversationIDs = []

            state.loadMemoryUsageData()

            #expect(state.memoryUsageCount == convIDs.count)
            #expect(state.memoryUsageConversationIDs == Set(convIDs))
        }
    }
}
