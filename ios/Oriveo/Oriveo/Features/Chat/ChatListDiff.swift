import Foundation

enum ChatListDiff {
    struct Result: Equatable {
        let deletes: [Int]
        let inserts: [Int]
        /// New indexes (same id, render model changed).
        ///
        /// Not old indexes: calling `reconfigureItems` inside a `performBatchUpdates` closure makes UIKit
        /// look up the existing cell **immediately** by the given number in the pre-update visible table,
        /// then ask the already-committed dataSource with **the same number**. When an insert or delete
        /// before the row shifts it, the two land on different messages: the cell gets the wrong content,
        /// and when the roles differ the dequeued reuse identifier does not match the existing cell and
        /// UIKit crashes. A shifted reconfigure therefore waits until the structural change is committed
        /// and runs separately with new indexes (see `reconfiguresShiftedByStructure`).
        let reconfigures: [Int]
        /// At least one reconfigured row has a different old and new index (shifted by an insert or delete
        /// in the same update): it cannot share a batch with the structural change, so the controller
        /// commits the structural change first and reconfigures with new indexes in a separate batch.
        let reconfiguresShiftedByStructure: Bool
        let requiresFullReload: Bool

        init(
            deletes: [Int],
            inserts: [Int],
            reconfigures: [Int],
            reconfiguresShiftedByStructure: Bool = false,
            requiresFullReload: Bool = false
        ) {
            self.deletes = deletes
            self.inserts = inserts
            self.reconfigures = reconfigures
            self.reconfiguresShiftedByStructure = reconfiguresShiftedByStructure
            self.requiresFullReload = requiresFullReload
        }

        var isEmpty: Bool { deletes.isEmpty && inserts.isEmpty && reconfigures.isEmpty }

        var hasStructuralChange: Bool { !deletes.isEmpty || !inserts.isEmpty }
    }

    static func diff(
        oldIDs: [UUID],
        newIDs: [UUID],
        isReconfigured: (UUID) -> Bool
    ) -> Result {
        let oldIDSet = Set(oldIDs)
        let newIDSet = Set(newIDs)

        let hasDuplicateIDs = oldIDSet.count != oldIDs.count || newIDSet.count != newIDs.count
        let oldCommon = oldIDs.filter { newIDSet.contains($0) }
        let newCommon = newIDs.filter { oldIDSet.contains($0) }
        if hasDuplicateIDs || oldCommon != newCommon {
            return Result(deletes: [], inserts: [], reconfigures: [], requiresFullReload: true)
        }

        let oldIndexByID = Dictionary(
            oldIDs.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var deletes: [Int] = []
        for (index, id) in oldIDs.enumerated() where !newIDSet.contains(id) {
            deletes.append(index)
        }
        var inserts: [Int] = []
        for (index, id) in newIDs.enumerated() where !oldIDSet.contains(id) {
            inserts.append(index)
        }
        var reconfigures: [Int] = []
        var shifted = false
        for (newIndex, id) in newIDs.enumerated() where oldIDSet.contains(id) && isReconfigured(id) {
            reconfigures.append(newIndex)
            if oldIndexByID[id] != newIndex { shifted = true }
        }

        return Result(
            deletes: deletes,
            inserts: inserts,
            reconfigures: reconfigures,
            reconfiguresShiftedByStructure: shifted
        )
    }
}
