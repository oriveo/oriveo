import Foundation
import Testing
@testable import Oriveo

@Suite("ChatListDiff")
struct ChatListDiffTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private func noReconfig(_: UUID) -> Bool { false }

    @Test("Append At End")
    func appendAtEnd() {
        let result = ChatListDiff.diff(oldIDs: [a, b], newIDs: [a, b, c], isReconfigured: noReconfig)
        #expect(result.inserts == [2])
        #expect(result.deletes.isEmpty)
        #expect(result.reconfigures.isEmpty)
        #expect(result.hasStructuralChange)
    }

    @Test("Prepend At Head")
    func prependAtHead() {
        let result = ChatListDiff.diff(oldIDs: [c, d], newIDs: [a, b, c, d], isReconfigured: noReconfig)
        #expect(result.inserts == [0, 1])
        #expect(result.deletes.isEmpty)
        #expect(result.reconfigures.isEmpty)
    }

    @Test("Reconfigure Same ID")
    func reconfigureSameID() {
        let result = ChatListDiff.diff(oldIDs: [a, b], newIDs: [a, b]) { $0 == b }
        #expect(result.reconfigures == [1])
        #expect(result.inserts.isEmpty)
        #expect(result.deletes.isEmpty)
        #expect(!result.hasStructuralChange)
        #expect(!result.isEmpty)
    }

    @Test("Delete Middle")
    func deleteMiddle() {
        let result = ChatListDiff.diff(oldIDs: [a, b, c], newIDs: [a, c], isReconfigured: noReconfig)
        #expect(result.deletes == [1])
        #expect(result.inserts.isEmpty)
        #expect(result.reconfigures.isEmpty)
    }

    @Test("Append Plus Reconfigure")
    func appendPlusReconfigure() {
        let result = ChatListDiff.diff(oldIDs: [a, b], newIDs: [a, b, c]) { $0 == b }
        #expect(result.inserts == [2])
        #expect(result.reconfigures == [1])
        #expect(result.deletes.isEmpty)
    }

    @Test("Delete Plus Insert")
    func deletePlusInsert() {
        let result = ChatListDiff.diff(oldIDs: [a, b, c], newIDs: [a, c, d], isReconfigured: noReconfig)
        #expect(result.deletes == [1])
        #expect(result.inserts == [2])
        #expect(result.reconfigures.isEmpty)
    }

    @Test("Empty To Populated")
    func emptyToPopulated() {
        let result = ChatListDiff.diff(oldIDs: [], newIDs: [a, b], isReconfigured: noReconfig)
        #expect(result.inserts == [0, 1])
        #expect(result.deletes.isEmpty)
    }

    @Test("Populated To Empty")
    func populatedToEmpty() {
        let result = ChatListDiff.diff(oldIDs: [a, b], newIDs: [], isReconfigured: noReconfig)
        #expect(result.deletes == [0, 1])
        #expect(result.inserts.isEmpty)
    }

    @Test("No Change")
    func noChange() {
        let result = ChatListDiff.diff(oldIDs: [a, b], newIDs: [a, b], isReconfigured: noReconfig)
        #expect(result.isEmpty)
    }

    @Test("Reconfigure Only For Surviving")
    func reconfigureOnlyForSurviving() {
        let result = ChatListDiff.diff(oldIDs: [a], newIDs: [a, c]) { _ in true }
        #expect(result.inserts == [1])
        #expect(result.reconfigures == [0])
    }

    @Test("Reorder Requires Full Reload")
    func reorderRequiresFullReload() {
        let result = ChatListDiff.diff(oldIDs: [a, b], newIDs: [b, a], isReconfigured: noReconfig)
        #expect(result.requiresFullReload)
        #expect(result.deletes.isEmpty)
        #expect(result.inserts.isEmpty)
        #expect(result.reconfigures.isEmpty)
    }

    @Test("Reorder With Insert Requires Full Reload")
    func reorderWithInsertRequiresFullReload() {
        let result = ChatListDiff.diff(oldIDs: [a, b], newIDs: [b, c, a], isReconfigured: noReconfig)
        #expect(result.requiresFullReload)
    }

    @Test("Duplicate I Ds Require Full Reload")
    func duplicateIDsRequireFullReload() {
        let result = ChatListDiff.diff(oldIDs: [a, a], newIDs: [a, b], isReconfigured: noReconfig)
        #expect(result.requiresFullReload)
    }

    @Test("Normal Updates Do Not Require Full Reload")
    func normalUpdatesDoNotRequireFullReload() {
        #expect(!ChatListDiff.diff(oldIDs: [a, b], newIDs: [a, b, c], isReconfigured: noReconfig).requiresFullReload)
        #expect(!ChatListDiff.diff(oldIDs: [c, d], newIDs: [a, b, c, d], isReconfigured: noReconfig).requiresFullReload)
        #expect(!ChatListDiff.diff(oldIDs: [a, b, c], newIDs: [a, c], isReconfigured: noReconfig).requiresFullReload)
        #expect(!ChatListDiff.diff(oldIDs: [a, b], newIDs: [a, b]) { $0 == b }.requiresFullReload)
    }
}
