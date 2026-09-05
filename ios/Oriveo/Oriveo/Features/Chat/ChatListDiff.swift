import Foundation

enum ChatListDiff {
    struct Result: Equatable {
        let deletes: [Int]
        let inserts: [Int]
        let reconfigures: [Int]
        let requiresFullReload: Bool

        init(deletes: [Int], inserts: [Int], reconfigures: [Int], requiresFullReload: Bool = false) {
            self.deletes = deletes
            self.inserts = inserts
            self.reconfigures = reconfigures
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
        for id in newIDs where oldIDSet.contains(id) && isReconfigured(id) {
            if let oldIndex = oldIndexByID[id] { reconfigures.append(oldIndex) }
        }

        return Result(deletes: deletes, inserts: inserts, reconfigures: reconfigures.sorted())
    }
}
