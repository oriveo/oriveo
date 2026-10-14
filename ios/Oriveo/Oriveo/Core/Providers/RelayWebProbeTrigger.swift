import Foundation

// MARK: - Automatic triggering of relay web-search probes
//
// There are only two automatic moments: a successful save on the Web Search page (one save = one event), and enabling after a lazy verification that actually ran and passed.
// All other moments (adding a connection, re-detection, swapping a key, refreshing the catalog, launch) never probe. Manual probes (test panel, re-test on the Web Search page)
// have no cap, no de-duplication, and do not enter the auto history. The criteria follow `triggers` in `shared/test-fixtures/relay/web-probe.v1.json`.

enum RelayWebProbeTrigger {
    /// How many to probe at most per automatic event (shared across the whole save, not split by protocol).
    static let perSave = 5
    /// How many to probe automatically at most within the rolling window of each connection.
    static let perConnectionPerWindow = 10
    /// Rolling window: only now - sentAt < windowSeconds counts, independent of time zone.
    static let windowSeconds: TimeInterval = 86_400

    enum LazyVerify: Equatable, Sendable { case passed, failed, notRun }

    enum Event: Equatable, Sendable {
        case saveFragment
        case enableModel(LazyVerify)
        case manualTest
        case retest
        case redetect
        case addConnection
    }

    /// One candidate: model x first-send protocol x the hash of that protocol's current fragment.
    struct Candidate: Hashable, Sendable {
        let modelID: String
        let transport: String
        let fragmentHash: String
    }

    /// One auto-history entry: written only by automatic probes, before sending.
    nonisolated struct HistoryEntry: Codable, Equatable, Sendable {
        let connectionID: String
        let modelID: String
        let transport: String
        let fragmentHash: String
        let sentAt: Date

        func dedupes(_ candidate: Candidate) -> Bool {
            modelID == candidate.modelID && transport == candidate.transport && fragmentHash == candidate.fragmentHash
        }
    }

    struct Selection: Equatable, Sendable {
        var probe: [Candidate]
        var untested: [Candidate]
        /// Automatic probes count toward the cap and write history; manual ones do not count.
        var countsTowardCap: Bool

        static let none = Selection(probe: [], untested: [], countsTowardCap: false)
    }

    /// Selection (fixture `triggerCases`): non-RELAY never probes; manual / re-test probes everything as listed; automatic first drops, in candidate order, those whose de-duplication key is already in the history
    /// (they take no quota), then takes the first min(perSave, window headroom) to probe, and reports the rest as untested. Only this connection's history is counted.
    static func select(
        event: Event, form: ProviderForm, candidates: [Candidate], history: [HistoryEntry], now: Date, connectionID: String
    ) -> Selection {
        guard form == .relay else { return .none }
        switch event {
        case .redetect, .addConnection, .enableModel(.failed), .enableModel(.notRun):
            return .none
        case .manualTest, .retest:
            return Selection(probe: candidates, untested: [], countsTowardCap: false)
        case .saveFragment, .enableModel(.passed):
            let own = history.filter { $0.connectionID == connectionID }
            let used = own.filter { isInWindow($0, now: now) }.count
            let fresh = candidates.filter { candidate in !own.contains { $0.dedupes(candidate) } }
            let slots = max(0, min(perSave, perConnectionPerWindow - used))
            return Selection(probe: Array(fresh.prefix(slots)), untested: Array(fresh.dropFirst(slots)), countsTowardCap: true)
        }
    }

    static func isInWindow(_ entry: HistoryEntry, now: Date) -> Bool {
        now.timeIntervalSince(entry.sentAt) < windowSeconds
    }

    /// Prune history on save: delete entries of this connection that are out of the window and whose (protocol, hash) is not the current fragment of that protocol; other connections are untouched.
    /// The `currentHashes` key = the protocol's wire value.
    static func pruned(
        _ history: [HistoryEntry], connectionID: String, currentHashes: [String: String], now: Date
    ) -> [HistoryEntry] {
        history.filter { entry in
            entry.connectionID != connectionID
                || isInWindow(entry, now: now)
                || currentHashes[entry.transport] == entry.fragmentHash
        }
    }
}

/// Dependencies used by automatic probing: send (nil = production upstream), fragment store, record and history stores.
struct RelayWebProbeAutoContext {
    var send: RelayWebProbe.Send?
    var fragments: RelayWebFragmentStore
    var records: RelayWebProbeStore

    init(send: RelayWebProbe.Send? = nil, fragments: RelayWebFragmentStore = .shared, records: RelayWebProbeStore = .shared) {
        self.send = send
        self.fragments = fragments
        self.records = records
    }
}
