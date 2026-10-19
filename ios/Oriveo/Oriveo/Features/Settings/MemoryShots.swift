#if DEBUG
import Foundation
import OriveoProviderKit
import UIKit

/// Debug direct-open pages for the memory page family: used for screenshot samples; nothing from this file exists in Release builds.
///
/// Usage: `xcrun simctl launch <udid> ai.oriveo.community -AUTO_OPEN_PAGE <page name>`; page names are listed in `Shot`.
/// When launched with these page names the whole process uses an in-memory `AppState` (`OriveoApp.init` goes through `seedDemoData` according to `isRequested`).
///
/// Data is read only from the manifest shared by all platforms (`test-fixtures/shots/memory.v1.json` in the shared directory): items go through the production `MemoryItem` decoder
/// (missing fields take the contract defaults), candidates are built in memory through the production `MemoryCandidate` decoder; when the manifest cannot be read or a field is missing, opening is refused
/// and no hard-coded values are used as a fallback. It never reads or writes the real database and never touches the network.
///
/// Private page state cannot be set up from outside, so each page got a `#if DEBUG` injection point (marked "screenshots only" next to it):
/// 1. `MemoryItemsCache.pinForShots`:swap in in-memory items and detach the database observation.
/// 2. `MemoryInboxModel.reload`:use `candidates` directly when it has a value, without reading the candidate store.
/// 3. `MemoryView.initialDeviceId` / `folderNames` / `computeHasRecentConversations`：the manifest's deviceId, folder names and whether there are recent conversations.
/// 4. `MemoryView.onAppear`:open the raw text page when `takeRawEditor()` has a value.
/// The two editor pages go through the production `openMemory(editItemId:)` (the same path as "This is wrong").
enum MemoryShots {
    enum Shot: String, CaseIterable {
        case memoryStarter, memoryList, memoryInbox, memoryEditorL2, memoryEditorL3, memoryRaw
    }

    /// The launch arguments name a page of this family.
    static var isRequested: Bool { requestedShot(in: CommandLine.arguments) != nil }

    /// The page of this family named by `-AUTO_OPEN_PAGE <page name>`; nil when none is named or it is not of this family.
    static func requestedShot(in arguments: [String]) -> Shot? {
        guard let index = arguments.firstIndex(of: "-AUTO_OPEN_PAGE"), index + 1 < arguments.count else { return nil }
        return Shot(rawValue: arguments[index + 1])
    }

    /// With `-SHOTS_SCROLL_BOTTOM` and a page of this family named: scroll to the very bottom once the list is ready, then capture (the L3 timeline and the lower half of the groups).
    /// The simulator has no input injection, so launch arguments are the only way.
    static func scrollToBottom(in arguments: [String]) -> Bool {
        requestedShot(in: arguments) != nil && arguments.contains("-SHOTS_SCROLL_BOTTOM")
    }

    static var isScrollToBottomRequested: Bool { scrollToBottom(in: CommandLine.arguments) }

    /// Scroll the largest vertically scrollable view on the current page (the memory list) to the bottom, without animation.
    /// Returns whether it moved this time: a lazy list recomputes its content height after scrolling to the bottom, so the caller must call repeatedly until it stops moving.
    @MainActor
    @discardableResult
    static func scrollListToBottom() -> Bool {
        guard let scrollView = largestVerticalScrollView() else { return false }
        let inset = scrollView.adjustedContentInset
        let bottom = max(-inset.top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        guard abs(scrollView.contentOffset.y - bottom) > 0.5 else { return false }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottom), animated: false)
        scrollView.layoutIfNeeded()
        return true
    }

    @MainActor
    private static func largestVerticalScrollView() -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
        var best: UIScrollView?
        var bestArea: CGFloat = 0
        func visit(_ view: UIView) {
            if view.isHidden || view.alpha < 0.01 { return }
            if let scrollView = view as? UIScrollView, !(scrollView is UITextView),
               scrollView.contentSize.height > scrollView.bounds.height {
                let area = scrollView.bounds.width * scrollView.bounds.height
                if area > bestArea {
                    best = scrollView
                    bestArea = area
                }
            }
            view.subviews.forEach(visit)
        }
        visit(window)
        return best
    }

    // MARK: - State read by the injection points

    private static var staged: Staged?
    private static var pendingRawEditor: MemoryRawEditorState?

    /// The deviceId used to decide "this device" in conflict pairs; nil when no sample is set up.
    static var deviceId: String? { staged?.deviceId }
    /// Manifest folder id to name (L3 scope text).
    static var folderNames: [String: String] { staged?.folderNames ?? [:] }
    /// Candidates for the candidate inbox / suggestion entry; nil when no sample is set up (uses the production store).
    static var candidates: [MemoryCandidate]? { staged?.candidates }
    /// Whether there are recent conversations, as the manifest dictates; nil when no sample is set up (uses the production check).
    static var hasRecentConversations: Bool? { staged?.hasRecentConversations }

    /// The raw text page is handed out only once: onAppear fires again when the page is covered and revealed.
    static func takeRawEditor() -> MemoryRawEditorState? {
        defer { pendingRawEditor = nil }
        return pendingRawEditor
    }

    // MARK: - Entry

    static func open(_ shot: Shot, appState: AppState) async {
        // With a persistent store the placed items could be washed out by database observation or written by mistake, so do not place them.
        guard !appState.prefersAuthoritativeConversationStore else {
            report("\(shot.rawValue): AppState is not in-memory; demo data was not injected")
            return
        }
        let staged: Staged
        do {
            staged = try stage(shot, manifestData: manifestData())
        } catch {
            report("\(shot.rawValue)：\(error)")
            return
        }
        self.staged = staged
        pendingRawEditor = staged.rawEditor
        appState.memoryItemsCache.pinForShots(staged.items)
        // The demo seed hard-codes the dark theme; samples follow the system, with light / dark decided by simctl appearance
        appState.preferences.theme = .system
        appState.selectedTab = .settings
        appState.navigation.reset(to: [])
        switch shot {
        case .memoryInbox:
            appState.navigation.reset(to: [.memory, .memoryInbox])
        case .memoryEditorL2, .memoryEditorL3:
            appState.openMemory(editItemId: staged.editItem)
        case .memoryStarter, .memoryList, .memoryRaw:
            appState.openMemory()
        }
    }

    // MARK: - Manifest to in-memory objects

    struct Staged {
        let items: [MemoryItem]
        let candidates: [MemoryCandidate]
        let deviceId: String
        let hasRecentConversations: Bool
        let folderNames: [String: String]
        let editItem: String?
        let rawEditor: MemoryRawEditorState?
    }

    enum ManifestError: Error, CustomStringConvertible {
        case repositoryNotFound
        case invalid(String)

        var description: String {
            switch self {
            case .repositoryNotFound: "Walking up from the source file location did not find a repository root containing the shared directory"
            case let .invalid(reason): reason
            }
        }
    }

    /// The shape of the manifest; keys starting with `$` are notes and are not read. Items and candidates stay as JSON objects and are handed to the production decoders.
    struct Manifest: Decodable {
        struct Folder: Decodable {
            let id: String
            let name: String
        }

        struct Page: Decodable {
            struct Preset: Decodable {
                let editItem: String?
                let rawTooLongAt: Int?
            }

            let name: String
            let items: String
            let candidates: String
            let preset: Preset?
        }

        struct TooLongSegment: Decodable {
            let unit: String
            let `repeat`: Int
        }

        let schema: String
        let clock: String
        let deviceId: String
        let hasRecentConversations: Bool
        let folders: [Folder]
        let pages: [Page]
        let rawTooLongSegment: TooLongSegment

        static func load(from data: Data) throws -> Manifest {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schema == "oriveo.shots.memory/v1" else {
                throw ManifestError.invalid("schema is not oriveo.shots.memory/v1: \(manifest.schema)")
            }
            return manifest
        }
    }

    /// Read the manifest and build everything this page needs; any failing step throws and the caller refuses to open.
    static func stage(_ shot: Shot, manifestData data: Data) throws -> Staged {
        let manifest = try Manifest.load(from: data)
        guard let page = manifest.pages.first(where: { $0.name == shot.rawValue }) else {
            throw ManifestError.invalid("The manifest has no page \(shot.rawValue)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = root["items"] as? [[String: Any]],
              let rawCandidates = root["candidates"] as? [[String: Any]] else {
            throw ManifestError.invalid("The manifest lacks items / candidates")
        }
        guard let clock = MemoryEpisodicTime.parse(manifest.clock) else {
            throw ManifestError.invalid("clock is not RFC 3339: \(manifest.clock)")
        }
        let clockMs = Int64((clock.timeIntervalSince1970 * 1000).rounded())

        let items = try choose(page.items, field: "items") {
            try rawItems.map { try item($0, deviceId: manifest.deviceId) }
        }
        let candidates = try choose(page.candidates, field: "candidates") {
            try rawCandidates.map { try candidate($0, clockMs: clockMs) }
                .sorted { $0.createdAtMs > $1.createdAtMs }
        }

        let editItem = page.preset?.editItem
        if let editItem, MemoryItemEditorState.edit(itemId: editItem, in: items) == nil {
            throw ManifestError.invalid("preset.editItem did not find an editable item: \(editItem)")
        }

        var rawEditor: MemoryRawEditorState?
        if let index = page.preset?.rawTooLongAt {
            let segment = String(repeating: manifest.rawTooLongSegment.unit, count: manifest.rawTooLongSegment.repeat)
            rawEditor = try tooLongRawEditor(items: items, index: index, segment: segment)
        }

        return Staged(
            items: items,
            candidates: candidates,
            deviceId: manifest.deviceId,
            hasRecentConversations: manifest.hasRecentConversations,
            folderNames: Dictionary(
                manifest.folders.map { ($0.id.lowercased(), $0.name) },
                uniquingKeysWith: { first, _ in first }
            ),
            editItem: editItem,
            rawEditor: rawEditor
        )
    }

    private static func choose<T>(_ selector: String, field: String, all: () throws -> [T]) throws -> [T] {
        switch selector {
        case "all": return try all()
        case "none": return []
        default: throw ManifestError.invalid("pages.\(field) only accepts all / none: \(selector)")
        }
    }

    /// Manifest item to production decoder. Device-local fields the manifest does not give: mutationId is derived from id, deviceId takes the manifest deviceId
    /// (a conflict copy has id != conflictGroupId, i.e. "this device's version"); an `occurredAt` that is only a date is completed to 00:00:00Z of that day (how the editor stores it).
    static func item(_ raw: [String: Any], deviceId: String) throws -> MemoryItem {
        var object = raw
        guard let id = object["id"] as? String else { throw ManifestError.invalid("Item lacks id") }
        if object["mutationId"] == nil { object["mutationId"] = "shots-\(id)" }
        if object["deviceId"] == nil { object["deviceId"] = deviceId }
        if let day = object["occurredAt"] as? String, day.count == 10 {
            object["occurredAt"] = day + "T00:00:00Z"
        }
        do {
            return try JSONDecoder().decode(MemoryItem.self, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            throw ManifestError.invalid("Item \(id) failed to decode: \(error)")
        }
    }

    /// Candidate lifetime (the same value as ProviderKit `MemoryIntentLexicon.candidateTtlMs`, which is not exposed).
    private static let candidateTtlMs: Int64 = 2_592_000_000

    /// Manifest candidate to production decoder: pending, fingerprint via the production `MemoryIntent.fingerprint`, time from the manifest createdAt,
    /// expiry = manifest clock + lifetime (samples are never expired).
    static func candidate(_ raw: [String: Any], clockMs: Int64) throws -> MemoryCandidate {
        guard let id = raw["id"] as? String,
              let content = raw["content"] as? String,
              let createdAt = (raw["createdAt"] as? String).flatMap(MemoryEpisodicTime.parse) else {
            throw ManifestError.invalid("Candidate lacks id / content / createdAt")
        }
        let createdAtMs = Int64((createdAt.timeIntervalSince1970 * 1000).rounded())
        let object: [String: Any] = [
            "id": id,
            "status": "pending",
            "proposedLayer": raw["proposedLayer"] ?? "semantic",
            "proposedKind": raw["proposedKind"] ?? NSNull(),
            "content": content,
            "scope": raw["scope"] ?? ["type": "global", "id": NSNull()],
            "source": [
                "type": "conversation",
                "conversationId": NSNull(),
                "messageIds": [String](),
                "observedAtMs": createdAtMs
            ] as [String: Any],
            "sensitivity": "normal",
            "confidence": raw["confidence"] ?? 0.7,
            "fingerprint": MemoryIntent.fingerprint(content),
            "createdAtMs": createdAtMs,
            "expiresAtMs": clockMs + candidateTtlMs,
            "resolvedAtMs": NSNull()
        ]
        do {
            return try JSONDecoder().decode(MemoryCandidate.self, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            throw ManifestError.invalid("Candidate \(id) failed to decode: \(error)")
        }
    }

    /// Raw text page: in the text produced by the production rawRender, replace section `index` with an over-long section, then run the production prepareSave to get tooLong (no item is written).
    static func tooLongRawEditor(items: [MemoryItem], index: Int, segment: String) throws -> MemoryRawEditorState {
        var state = MemoryRawEditorState(items: items)
        let separator = "\n\(MemoryItems.rawViewSeparator)\n"
        var segments = state.text.components(separatedBy: separator)
        guard segments.indices.contains(index) else {
            throw ManifestError.invalid("rawTooLongAt out of range: \(index) / \(segments.count)")
        }
        segments[index] = segment
        state.text = segments.joined(separator: separator)
        guard state.prepareSave() == nil, state.tooLongMessage != nil else {
            throw ManifestError.invalid("The over-long section was not judged tooLong")
        }
        return state
    }

    // MARK: - Manifest location

    /// The manifest is not in the bundle: the simulator process can read host files, so walk up from this source file location to the repository root that contains the shared directory.
    static func manifestURL(sourceFile: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
        while directory.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            let shared = directory.appendingPathComponent("shared")
            if FileManager.default.fileExists(atPath: shared.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return shared.appendingPathComponent("test-fixtures/shots/memory.v1.json")
            }
            directory.deleteLastPathComponent()
        }
        throw ManifestError.repositoryNotFound
    }

    static func manifestData() throws -> Data {
        try Data(contentsOf: manifestURL())
    }

    private static func report(_ message: String) {
        print("[MemoryShots] \(message)")
    }
}
#endif
