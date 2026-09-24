import Foundation
import Observation

/// The `ModelDisplayLookup` that Home and folder conversation rows, and the chat message metadata, share to resolve
/// model display names.
///
/// It must refresh whenever providers change: fingerprint the whole catalog, and rebuild when the fingerprint
/// changes (one metadata lookup per catalog model, four sets of lookup keys, two date-suffix regexes each). A relay
/// catalog comes from the user's own server and can hold over 20,000 models, and both steps grow linearly with it;
/// they used to run on the main thread in Home. They now run in the background and are reused by fingerprint, so the
/// main thread only reads a finished lookup.
///
/// Ordering: refreshes chain in call order; a refresh is skipped when a newer one is already queued (the newest one
/// does the work); built results merge in chain order, so `lookup` only moves forward and an older result never
/// overwrites a newer one. A fingerprint equal to the merged one is neither rebuilt nor replaced.
@MainActor
@Observable
final class ConversationModelLookupStore {
    /// `.empty` until the first build finishes, with `isReady == false`: callers must not show its fallback as a
    /// display name.
    private(set) var lookup: ModelDisplayLookup = .empty
    private(set) var isReady = false
    /// Goes up by one each time a new lookup is merged. The chat screen folds it into its row metadata version, so a
    /// merge rebuilds the rows and refreshes the visible cells.
    private(set) var revision: UInt = 0
    @ObservationIgnored private var fingerprint: Int?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private(set) var buildCountForTesting = 0

    private struct Built: Sendable {
        let fingerprint: Int
        let lookup: ModelDisplayLookup
    }

    func refresh(providers: [Provider], metadata: MetadataClient = .shared) {
        generation &+= 1
        let requested = generation
        let previous = refreshTask
        refreshTask = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == requested else { return }
            let committed = self.fingerprint
            let built = await Task.detached(priority: .userInitiated) { () -> Built? in
                let fingerprint = ModelDisplayLookup.fingerprint(providers: providers, metadata: metadata)
                guard fingerprint != committed else { return nil }
                let lookup = ModelDisplayLookup(providers: providers, metadata: metadata)
                lookup.prewarm()
                return Built(fingerprint: fingerprint, lookup: lookup)
            }.value
            guard let built else { return }
            self.lookup = built.lookup
            self.fingerprint = built.fingerprint
            self.isReady = true
            self.revision &+= 1
            self.buildCountForTesting += 1
        }
    }

#if DEBUG
    /// Tests only: waits until every queued refresh has finished (returns at once when none is in flight).
    func waitForRefreshForTesting() async {
        await refreshTask?.value
    }
#endif
}
