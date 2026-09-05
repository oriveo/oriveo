import Foundation
@testable import Oriveo

// MARK: - MockAppSessionStore

final class MockAppSessionStore {


    private(set) var storedSnapshot: AppSessionSnapshot?
    private(set) var saveCallCount = 0
    private(set) var loadCallCount = 0
    private(set) var clearCallCount = 0


    func save(_ snapshot: AppSessionSnapshot) {
        saveCallCount += 1
        storedSnapshot = snapshot
    }

    func load() -> AppSessionSnapshot? {
        loadCallCount += 1
        return storedSnapshot
    }

    func clear() {
        clearCallCount += 1
        storedSnapshot = nil
    }


    func reset() {
        storedSnapshot = nil
        saveCallCount = 0
        loadCallCount = 0
        clearCallCount = 0
    }
}
