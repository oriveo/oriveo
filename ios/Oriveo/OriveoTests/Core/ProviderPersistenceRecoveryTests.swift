import Foundation
import Testing
@testable import Oriveo

@Suite("ProviderPersistenceRecovery", .serialized)
struct ProviderPersistenceRecoveryTests {

    @Test("loadSession clears leftover persisted syncing provider state")
    @MainActor
    func loadSessionRecoversPersistedSyncingProvider() {
        let previousUID = AppSessionStore.activeUID
        let uid = "provider-persist-recovery-\(UUID().uuidString)"

        defer {
            DatabaseManager.shared.close()
            AppSessionStore.switchToUser(previousUID)
            try? FileManager.default.removeItem(at: AppSessionStore.userDir(for: uid))
        }

        DatabaseManager.shared.close()

        let state = AppState(sessionUID: uid)
        state.providers = [
            TestFactories.makeProvider(
                kind: .openAI,
                status: .syncing,
                models: [TestFactories.makeModel(id: "gpt-4.1", isDefault: true)],
                lastCheckedAt: Date(timeIntervalSince1970: 1_710_000_000)
            ),
        ]
        state.persistSessionNow()

        DatabaseManager.shared.close()

        let recovered = AppState(sessionUID: uid)

        #expect(recovered.providers.count == 1)
        #expect(recovered.providers[0].status == .connected)
    }

}
