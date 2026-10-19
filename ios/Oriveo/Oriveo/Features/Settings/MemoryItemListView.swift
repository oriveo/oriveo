import OriveoProviderKit
import SwiftUI

// Grouped item list of Settings > Memory: conflict groups / About me / Preferences / Standing instructions / Projects.
// Presentation rules live in `MemoryItemListPresentation`(pure values, tested directly); the view only renders and calls back.

/// The four groups, which are also the four categories of the editor.
enum MemoryItemGroup: String, CaseIterable, Identifiable, Sendable {
    case about
    case preferences
    case instructions
    case projects

    var id: String { rawValue }

    /// The group an item belongs to; event is not shown, so nil.
    init?(kind: MemoryKind) {
        switch kind {
        case .identity, .fact: self = .about
        case .preference: self = .preferences
        case .instruction, .constraint: self = .instructions
        case .project, .goal, .decision: self = .projects
        case .event: return nil
        }
    }

    /// The kind written when the editor picks this category: when the category did not change (the original kind is in this group) keep the original kind
    /// (fact / constraint / goal / decision are not rewritten); otherwise take the representative kind of this group.
    func kind(keeping original: MemoryKind?) -> MemoryKind {
        if let original, MemoryItemGroup(kind: original) == self { return original }
        return switch self {
        case .about: .identity
        case .preferences: .preference
        case .instructions: .instruction
        case .projects: .project
        }
    }

    var title: String {
        switch self {
        case .about: L10n.tr("memory_group_about", table: .chat)
        case .preferences: L10n.tr("memory_group_preferences", table: .chat)
        case .instructions: L10n.tr("memory_group_instructions", table: .chat)
        case .projects: L10n.tr("memory_group_projects", table: .chat)
        }
    }
}

struct MemoryItemRow: Equatable, Identifiable, Sendable {
    let item: MemoryItem

    var id: String { item.id }
    var isPinned: Bool { item.pinned }
    var showsPausedBadge: Bool { item.status == .paused }
    /// The inline "Organize into items" is offered only for migrated multi-line items (every live item has it in the menu).
    var showsOrganizeInline: Bool { item.source.type == .migration && item.content.contains("\n") }
}

struct MemoryItemSection: Equatable, Identifiable, Sendable {
    let group: MemoryItemGroup
    let rows: [MemoryItemRow]

    var id: String { group.id }
}

struct MemoryConflictEntry: Equatable, Identifiable, Sendable {
    let item: MemoryItem
    let isThisDevice: Bool

    var id: String { item.id }
}

/// One conflict group (the same conflictGroupId), with this device's version first.
struct MemoryConflictPair: Equatable, Identifiable, Sendable {
    let id: String
    let entries: [MemoryConflictEntry]
}

/// Sort time of an L3 (episodic) item: occurredAt, or createdAt when missing; unparseable ones go last.
enum MemoryEpisodicTime {
    static func date(of item: MemoryItem) -> Date? {
        parse(item.occurredAt) ?? parse(item.createdAt)
    }

    /// RFC 3339 to Date, with or without milliseconds.
    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    /// Newest first; for equal times the larger id comes first.
    static func isNewer(_ lhs: MemoryItem, than rhs: MemoryItem) -> Bool {
        let left = date(of: lhs) ?? .distantPast
        let right = date(of: rhs) ?? .distantPast
        if left != right { return left > right }
        return lhs.id.lowercased() > rhs.id.lowercased()
    }

    /// UTC date `YYYY-MM-DD`; an empty string when there is no time.
    static func dayLabel(of item: MemoryItem) -> String {
        guard let date = date(of: item) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The `MM-DD` used in conflict pairs.
    static func monthDayLabel(of item: MemoryItem) -> String {
        String(dayLabel(of: item).dropFirst(5))
    }
}

/// One row of the "Events and decisions" group: body text + gray "date · scope".
struct MemoryEpisodicRow: Equatable, Identifiable, Sendable {
    let item: MemoryItem
    let dateLabel: String
    let scopeLabel: String

    var id: String { item.id }
    var isPinned: Bool { item.pinned }
    var showsPausedBadge: Bool { item.status == .paused }
    var detailLabel: String { dateLabel.isEmpty ? scopeLabel : "\(dateLabel) · \(scopeLabel)" }

    /// Scope text; when the folder name cannot be found, use "Folder".
    static func scopeLabel(_ scope: MemoryScope, folderNames: [String: String]) -> String {
        switch scope.type {
        case .global:
            return L10n.tr("memory_scope_all", table: .chat)
        case .folder:
            if let id = scope.id?.lowercased(), let name = folderNames[id], !name.isEmpty {
                return String(format: L10n.tr("memory_scope_folder_named", table: .chat), name)
            }
            return L10n.tr("memory_scope_folder", table: .chat)
        case .conversation:
            return L10n.tr("memory_scope_conversation", table: .chat)
        }
    }
}

/// The "Events and decisions" group: active / paused L3 items, newest first; beyond `collapseLimit` items only the first ones are shown at first.
struct MemoryEpisodicSection: Equatable, Sendable {
    static let collapseLimit = 20

    let rows: [MemoryEpisodicRow]

    var isCollapsible: Bool { rows.count > Self.collapseLimit }

    func visibleRows(expanded: Bool) -> [MemoryEpisodicRow] {
        expanded ? rows : Array(rows.prefix(Self.collapseLimit))
    }

    /// "Show all (N)", where N is the total count.
    var showAllTitle: String {
        String(format: L10n.tr("memory_show_all", table: .chat), rows.count)
    }
}

/// The user's three choices in a conflict pair.
enum MemoryL3ConflictChoice: CaseIterable, Sendable {
    case keepNewer
    case keepOlder
    case keepBoth

    var resolution: MemoryConflictResolution {
        switch self {
        case .keepNewer: .useNew
        case .keepOlder: .useOld
        case .keepBoth: .keepBoth
        }
    }
}

/// A pair of L3 conflicts (two episodic items with status conflicted and the same conflictGroupId); newer = later time, and for equal times the larger id.
struct MemoryL3ConflictPair: Equatable, Identifiable, Sendable {
    let id: String
    let newer: MemoryItem
    let older: MemoryItem

    /// The L3 resolution that the user's choice maps to in the store.
    @discardableResult
    nonisolated func apply(_ choice: MemoryL3ConflictChoice, writer: MemoryItemWriter) throws -> [MemoryItem]? {
        try writer.resolveL3Conflict(newerId: newer.id, olderId: older.id, resolution: choice.resolution)
    }
}

struct MemoryItemListPresentation: Equatable, Sendable {
    let conflicts: [MemoryConflictPair]
    let sections: [MemoryItemSection]
    let l3Conflicts: [MemoryL3ConflictPair]
    let episodic: MemoryEpisodicSection

    var isEmpty: Bool { conflicts.isEmpty && sections.isEmpty && l3Conflicts.isEmpty && episodic.rows.isEmpty }

    /// - Parameters:
    ///   - items: store items (may contain tombstones, filtered here).
    ///   - deviceId: this device's deviceId, used to mark "this device's version" in a conflict group.
    ///   - folderNames: folder id (lowercase) to name, used for the scope text of L3 rows.
    static func resolve(items: [MemoryItem], deviceId: String, folderNames: [String: String] = [:]) -> Self {
        let hiddenStatuses: Set<MemoryStatus> = [.deleted, .superseded, .expired]
        let visible = MemoryItems.listOrder(items.filter {
            !hiddenStatuses.contains($0.status) && $0.kind != .event && $0.layer != .episodic
        })
        let localDevice = deviceId.lowercased()

        var conflictOrder: [String] = []
        var conflictMembers: [String: [MemoryItem]] = [:]
        var grouped: [MemoryItemGroup: [MemoryItemRow]] = [:]
        for item in visible {
            if item.status == .conflicted {
                let key = item.conflictGroupId?.lowercased() ?? item.id.lowercased()
                if conflictMembers[key] == nil { conflictOrder.append(key) }
                conflictMembers[key, default: []].append(item)
            } else if let group = MemoryItemGroup(kind: item.kind) {
                grouped[group, default: []].append(MemoryItemRow(item: item))
            }
        }

        // Look only at the deviceId of the conflict copy (id != conflictGroupId): the original item's deviceId is the device that pushed it and cannot be used.
        // If the copy was written by this device, the copy is "this device's version" and the original is the other one; otherwise the reverse.
        let conflicts = conflictOrder.map { key in
            let members = conflictMembers[key] ?? []
            let copyIsLocal = members.contains {
                $0.id.lowercased() != key && $0.deviceId.lowercased() == localDevice
            }
            let entries = members.map { item in
                let isOriginal = item.id.lowercased() == key
                let isThisDevice = isOriginal ? !copyIsLocal : item.deviceId.lowercased() == localDevice
                return MemoryConflictEntry(item: item, isThisDevice: isThisDevice)
            }
            return MemoryConflictPair(
                id: key,
                entries: entries.filter(\.isThisDevice) + entries.filter { !$0.isThisDevice }
            )
        }
        let sections = MemoryItemGroup.allCases.compactMap { group in
            grouped[group].map { MemoryItemSection(group: group, rows: $0) }
        }
        return Self(
            conflicts: conflicts,
            sections: sections,
            l3Conflicts: l3ConflictPairs(items),
            episodic: episodicSection(items, folderNames: folderNames)
        )
    }

    private static func episodicSection(_ items: [MemoryItem], folderNames: [String: String]) -> MemoryEpisodicSection {
        let rows = items
            .filter { $0.layer == .episodic && ($0.status == .active || $0.status == .paused) }
            .sorted { MemoryEpisodicTime.isNewer($0, than: $1) }
            .map {
                MemoryEpisodicRow(
                    item: $0,
                    dateLabel: MemoryEpisodicTime.dayLabel(of: $0),
                    scopeLabel: MemoryEpisodicRow.scopeLabel($0.scope, folderNames: folderNames)
                )
            }
        return MemoryEpisodicSection(rows: rows)
    }

    /// Only conflict groups that come in pairs (exactly two items) appear; sorted by the newer item, newest first.
    private static func l3ConflictPairs(_ items: [MemoryItem]) -> [MemoryL3ConflictPair] {
        var members: [String: [MemoryItem]] = [:]
        for item in items where item.layer == .episodic && item.status == .conflicted {
            guard let key = item.conflictGroupId?.lowercased() else { continue }
            members[key, default: []].append(item)
        }
        return members.compactMap { key, pair -> MemoryL3ConflictPair? in
            guard pair.count == 2 else { return nil }
            let sorted = pair.sorted { MemoryEpisodicTime.isNewer($0, than: $1) }
            return MemoryL3ConflictPair(id: key, newer: sorted[0], older: sorted[1])
        }
        .sorted { MemoryEpisodicTime.isNewer($0.newer, than: $1.newer) }
    }
}

/// An action in a list card, carried out by the memory page against the store or the editor.
enum MemoryItemListAction {
    case add(MemoryItemGroup)
    case edit(MemoryItem)
    case setPinned(MemoryItem, Bool)
    case setPaused(MemoryItem, Bool)
    case delete(MemoryItem)
    case keepConflict(MemoryItem)
    case resolveL3Conflict(MemoryL3ConflictPair, MemoryL3ConflictChoice)
    case addEpisodic
    case organize(MemoryItem)
}

/// Grouped list: conflict groups on top, empty groups show no heading; the "Add" next to each heading preselects that group.
/// Visuals follow the memory constellation design: group glyph + hue, amber forked conflict card, L3 date column + timeline.
struct MemoryItemListView: View {
    let presentation: MemoryItemListPresentation
    let onAction: (MemoryItemListAction) -> Void
    /// Whether "Show all" has been tapped when "Events and decisions" exceeds the collapse threshold.
    @State private var showsAllEpisodic = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !presentation.conflicts.isEmpty || !presentation.l3Conflicts.isEmpty {
                conflictSection
            }
            ForEach(presentation.sections) { section in
                groupSection(section)
            }
            episodicSection
        }
    }

    // MARK: Conflict groups

    private var conflictSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoryGroupHeader(
                glyph: .conflict,
                hue: OriveoTheme.Palette.warning,
                title: L10n.tr("memory_group_conflicts", table: .chat),
                count: presentation.conflicts.count + presentation.l3Conflicts.count
            ) { EmptyView() }

            VStack(spacing: 12) {
                ForEach(presentation.conflicts) { pair in
                    VStack(spacing: 0) {
                        ForEach(Array(pair.entries.enumerated()), id: \.element.id) { index, entry in
                            conflictRow(entry, index: index, count: pair.entries.count)
                        }
                    }
                    .memoryCard(outline: OriveoTheme.Palette.warningLine)
                }

                ForEach(presentation.l3Conflicts) { pair in
                    VStack(spacing: 0) {
                        l3ConflictRow(pair, item: pair.newer, isNewer: true)
                        l3ConflictRow(pair, item: pair.older, isNewer: false)
                        Button {
                            onAction(.resolveL3Conflict(pair, .keepBoth))
                        } label: {
                            HStack(spacing: 8) {
                                MemoryGlyph(kind: .keepBoth, size: 16)
                                Text(L10n.tr("memory_conflict_keep_both", table: .chat))
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(OriveoTheme.Palette.warning.opacity(0.06))
                            .overlay(alignment: .top) {
                                Rectangle().fill(OriveoTheme.Palette.warningLine).frame(height: 1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .memoryCard(outline: OriveoTheme.Palette.warningLine)
                }
            }
        }
    }

    private func conflictRow(_ entry: MemoryConflictEntry, index: Int, count: Int) -> some View {
        MemoryForkRow(
            isPrimary: index == 0,
            isDiamond: false,
            linksUp: index > 0,
            linksDown: index < count - 1,
            showsDivider: index > 0
        ) {
            Text(entry.isThisDevice
                 ? L10n.tr("memory_conflict_this_device", table: .chat)
                 : L10n.tr("memory_conflict_other_device", table: .chat))
        } content: {
            Text(entry.item.content)
        } action: {
            Button(L10n.tr("memory_conflict_keep", table: .chat)) {
                onAction(.keepConflict(entry.item))
            }
            .buttonStyle(MemoryPillButtonStyle(filled: false))
        }
    }

    private func l3ConflictRow(_ pair: MemoryL3ConflictPair, item: MemoryItem, isNewer: Bool) -> some View {
        MemoryForkRow(
            isPrimary: isNewer,
            isDiamond: true,
            linksUp: !isNewer,
            linksDown: isNewer,
            showsDivider: !isNewer
        ) {
            HStack(spacing: 4) {
                Text(isNewer ? L10n.tr("memory_conflict_newer", table: .chat) : L10n.tr("memory_conflict_older", table: .chat))
                let day = MemoryEpisodicTime.dayLabel(of: item)
                if !day.isEmpty {
                    Text(verbatim: "·")
                    Text(verbatim: day)
                        .font(OriveoTheme.Typography.brandDigits(11.5))
                        .foregroundStyle(OriveoTheme.Palette.textSecondary)
                }
            }
        } content: {
            Text(item.content)
        } action: {
            Button(L10n.tr("memory_conflict_keep", table: .chat)) {
                onAction(.resolveL3Conflict(pair, isNewer ? .keepNewer : .keepOlder))
            }
            .buttonStyle(MemoryPillButtonStyle(filled: false))
        }
    }

    // MARK: Events and decisions (L3)

    /// Always shown in edit mode (even with no items it has the group header "Add" and the group footer note): the only entry for creating L3 items by hand.
    private var episodicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoryGroupHeader(
                glyph: .episodic,
                hue: OriveoTheme.Palette.memoryHue.episodic,
                title: L10n.tr("memory_group_episodic", table: .chat),
                count: presentation.episodic.rows.count
            ) {
                Button {
                    onAction(.addEpisodic)
                } label: {
                    MemoryGroupAddLabel()
                }
                .buttonStyle(.plain)
            }

            let rows = presentation.episodic.visibleRows(expanded: showsAllEpisodic)
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        episodicRow(row, isFirst: index == 0)
                    }
                    if presentation.episodic.isCollapsible && !showsAllEpisodic {
                        Button {
                            showsAllEpisodic = true
                        } label: {
                            HStack {
                                Text(presentation.episodic.showAllTitle)
                                    .font(.system(size: 15, weight: .semibold))
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.forward")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                            .padding(.leading, MemoryTimeline.textInset)
                            .padding(.trailing, 14)
                            .frame(minHeight: 50)
                            .overlay(alignment: .top) { MemoryRowDivider(inset: MemoryTimeline.textInset) }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .memoryCard()
            }

            MemoryFootnote(systemImage: "iphone", text: L10n.tr("memory_episodic_local_only", table: .chat))
        }
    }

    private func episodicRow(_ row: MemoryEpisodicRow, isFirst: Bool) -> some View {
        let isEvent = row.item.kind == .event
        let parts = MemoryTimeline.dateParts(row.dateLabel)
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 0) {
                if let parts {
                    Text(verbatim: parts.monthDay)
                        .font(OriveoTheme.Typography.brandDigits(14))
                        .tracking(-0.2)
                        .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    Text(verbatim: parts.year)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(OriveoTheme.Palette.textTertiary)
                }
            }
            .frame(width: MemoryTimeline.dateWidth - 10, alignment: .trailing)
            .padding(.trailing, 10)
            .padding(.top, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.dateLabel)

            Color.clear.frame(width: MemoryTimeline.railWidth + 12, height: 1)

            Button {
                onAction(.edit(row.item))
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if row.isPinned {
                            MemoryPinMark(hue: OriveoTheme.Palette.memoryHue.episodic)
                        }
                        Text(row.item.content)
                            .font(.system(size: 16))
                            .lineSpacing(4)
                            .foregroundStyle(row.showsPausedBadge
                                             ? OriveoTheme.Palette.textTertiary
                                             : OriveoTheme.Palette.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    MemoryScopeTag(scope: row.item.scope.type, label: row.scopeLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if row.showsPausedBadge {
                MemoryPausedTag().padding(.top, 2)
            }
            MemoryMoreMenu { itemMenu(row.item) }
                .padding(.top, -6)
        }
        .padding(.vertical, 12)
        .padding(.trailing, 4)
        .frame(minHeight: 60, alignment: .top)
        .background(alignment: .topLeading) {
            MemoryTimelineRail(isFirst: isFirst, isEvent: isEvent, isPaused: row.showsPausedBadge)
        }
        .overlay(alignment: .top) {
            if !isFirst { MemoryRowDivider(inset: MemoryTimeline.textInset) }
        }
    }

    // MARK: Groups

    private func groupSection(_ section: MemoryItemSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MemoryGroupHeader(
                glyph: section.group.glyph,
                hue: section.group.hue,
                title: section.group.title,
                count: section.rows.count
            ) {
                Button {
                    onAction(.add(section.group))
                } label: {
                    MemoryGroupAddLabel()
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    itemRow(row, group: section.group)
                        .overlay(alignment: .top) {
                            if index > 0 { MemoryRowDivider(inset: 16) }
                        }
                }
            }
            .memoryCard()
        }
    }

    private func itemRow(_ row: MemoryItemRow, group: MemoryItemGroup) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                itemRowContent(row, group: group)
                if row.showsOrganizeInline {
                    Button {
                        onAction(.organize(row.item))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 12, weight: .semibold))
                            Text(L10n.tr("memory_action_organize", table: .chat))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(OriveoTheme.Palette.primaryTextSafe)
                        .padding(.leading, 10)
                        .padding(.trailing, 12)
                        .padding(.vertical, 6)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(OriveoTheme.Palette.primary.opacity(0.4), lineWidth: 1)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if row.showsPausedBadge {
                MemoryPausedTag()
            }
            MemoryMoreMenu { itemMenu(row.item) }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 13)
        .frame(minHeight: 56)
        .background(row.isPinned ? group.hue.opacity(colorScheme == .dark ? 0.10 : 0.07) : Color.clear)
    }

    private func itemRowContent(_ row: MemoryItemRow, group: MemoryItemGroup) -> some View {
        Button {
            onAction(.edit(row.item))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if row.isPinned {
                    MemoryPinMark(hue: group.hue)
                }
                Text(row.item.content)
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .foregroundStyle(row.showsPausedBadge
                                     ? OriveoTheme.Palette.textTertiary
                                     : OriveoTheme.Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func itemMenu(_ item: MemoryItem) -> some View {
        Button {
            onAction(.edit(item))
        } label: {
            Label(L10n.tr("memory_action_edit", table: .chat), systemImage: "pencil")
        }
        Button {
            onAction(.setPinned(item, !item.pinned))
        } label: {
            Label(
                item.pinned ? L10n.tr("memory_action_unpin", table: .chat) : L10n.tr("memory_action_pin", table: .chat),
                systemImage: item.pinned ? "pin.slash" : "pin"
            )
        }
        Button {
            onAction(.setPaused(item, item.status != .paused))
        } label: {
            Label(
                item.status == .paused
                    ? L10n.tr("memory_action_resume", table: .chat)
                    : L10n.tr("memory_action_pause", table: .chat),
                systemImage: item.status == .paused ? "play.circle" : "pause.circle"
            )
        }
        if item.layer != .episodic {
            Button {
                onAction(.organize(item))
            } label: {
                Label(L10n.tr("memory_action_organize", table: .chat), systemImage: "list.bullet.indent")
            }
        }
        Button(role: .destructive) {
            onAction(.delete(item))
        } label: {
            Label(L10n.tr("memory_action_delete", table: .chat), systemImage: "trash")
        }
    }
}

// MARK: - Shared memory constellation pieces (memory page / candidate inbox / editor / raw text)

extension MemoryItemGroup {
    /// Group hue: used for graphics only; text is always the body color.
    var hue: Color {
        switch self {
        case .about: OriveoTheme.Palette.memoryHue.about
        case .preferences: OriveoTheme.Palette.memoryHue.preferences
        case .instructions: OriveoTheme.Palette.memoryHue.instructions
        case .projects: OriveoTheme.Palette.memoryHue.workingOn
        }
    }

    var glyph: MemoryGlyph.Kind {
        switch self {
        case .about: .about
        case .preferences: .preferences
        case .instructions: .instructions
        case .projects: .workingOn
        }
    }
}

/// Line-style group glyph: 24 grid, 2pt stroke, colored only with no backing plate (the color comes from foregroundStyle).
struct MemoryGlyph: View {
    enum Kind {
        case about, preferences, instructions, workingOn, episodic
        case conflict, keepBoth, diamond, ring
    }

    let kind: Kind
    var size: CGFloat = 18

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 24
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            let (stroke, fill) = Self.paths(kind)
            let width: CGFloat = kind == .ring ? 2.6 : 2
            context.stroke(
                stroke.applying(transform),
                with: .foreground,
                style: StrokeStyle(lineWidth: width * scale, lineCap: .round, lineJoin: .round)
            )
            context.fill(fill.applying(transform), with: .foreground)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static func paths(_ kind: Kind) -> (stroke: Path, fill: Path) {
        var stroke = Path()
        var fill = Path()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        func dot(_ path: inout Path, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        switch kind {
        case .about:
            dot(&stroke, 12, 8.5, 3.5)
            stroke.move(to: p(5, 20))
            stroke.addCurve(to: p(12, 14.5), control1: p(6.4, 16.4), control2: p(9, 14.5))
            stroke.addCurve(to: p(19, 20), control1: p(15, 14.5), control2: p(17.6, 16.4))
        case .preferences:
            stroke.move(to: p(4, 8)); stroke.addLine(to: p(20, 8))
            stroke.move(to: p(4, 16)); stroke.addLine(to: p(20, 16))
            dot(&fill, 9, 8, 2.4)
            dot(&fill, 15, 16, 2.4)
        case .instructions:
            stroke.move(to: p(17, 4)); stroke.addLine(to: p(20, 7)); stroke.addLine(to: p(17, 10))
            stroke.move(to: p(20, 7)); stroke.addLine(to: p(9, 7))
            stroke.addArc(tangent1End: p(4, 7), tangent2End: p(4, 12), radius: 5)
            stroke.addArc(tangent1End: p(4, 17), tangent2End: p(9, 17), radius: 5)
            stroke.addLine(to: p(11, 17))
            stroke.move(to: p(14, 17)); stroke.addLine(to: p(20, 17))
        case .workingOn:
            stroke.addLines([p(12, 3), p(21, 7.5), p(12, 12), p(3, 7.5)])
            stroke.closeSubpath()
            stroke.addLines([p(3, 12), p(12, 16.5), p(21, 12)])
            stroke.addLines([p(3, 16.5), p(12, 21), p(21, 16.5)])
        case .episodic:
            stroke.move(to: p(12, 2)); stroke.addLine(to: p(12, 6))
            stroke.move(to: p(12, 18)); stroke.addLine(to: p(12, 22))
            stroke.addLines([p(12, 7), p(17, 12), p(12, 17), p(7, 12)])
            stroke.closeSubpath()
        case .conflict:
            dot(&stroke, 6, 5, 2)
            dot(&stroke, 6, 19, 2)
            dot(&stroke, 18, 12, 2)
            stroke.move(to: p(6, 7)); stroke.addLine(to: p(6, 17))
            stroke.move(to: p(6, 12)); stroke.addLine(to: p(10, 12))
            stroke.addQuadCurve(to: p(14, 8), control: p(14, 12))
            stroke.addLine(to: p(14, 7))
            stroke.move(to: p(14, 12)); stroke.addLine(to: p(16, 12))
        case .keepBoth:
            stroke.move(to: p(7, 6)); stroke.addLine(to: p(7, 18))
            stroke.move(to: p(17, 6)); stroke.addLine(to: p(17, 18))
        case .diamond:
            fill.addLines([p(12, 3), p(21, 12), p(12, 21), p(3, 12)])
            fill.closeSubpath()
        case .ring:
            dot(&stroke, 12, 12, 7.5)
        }
        return (stroke, fill)
    }
}

/// Dot-matrix texture at the page top: 1pt dots at 14pt spacing, fading downward; background only, carries no information.
struct MemoryAtlasBackdrop: View {
    var height: CGFloat = 360

    var body: some View {
        ZStack(alignment: .top) {
            OriveoTheme.Palette.backgroundGrouped
            Canvas { context, size in
                var dots = Path()
                var y: CGFloat = 7
                while y < size.height {
                    var x: CGFloat = 7
                    while x < size.width {
                        dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                        x += 14
                    }
                    y += 14
                }
                context.fill(dots, with: .color(OriveoTheme.Palette.memoryAtlasDot))
            }
            .frame(height: height)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.5), location: 0.45),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Memory page card face: opaque surface; light mode has two soft shadow layers, dark mode casts no shadow and uses a 1pt top highlight instead; conflict cards add an amber inner stroke.
struct MemoryCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let radius: CGFloat
    let outline: Color?
    let ring: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(OriveoTheme.Palette.backgroundGrouped)
                    shape.fill(OriveoTheme.Palette.surface)
                }
            }
            .clipShape(shape)
            .overlay {
                if let outline {
                    shape.strokeBorder(outline, lineWidth: 1)
                } else if ring {
                    shape.strokeBorder(OriveoTheme.Palette.border, lineWidth: 0.5)
                }
            }
            .overlay {
                if colorScheme == .dark {
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [OriveoTheme.Palette.hairline, .clear],
                                startPoint: .top,
                                endPoint: UnitPoint(x: 0.5, y: 0.2)
                            ),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: colorScheme == .dark ? .clear : OriveoTheme.Palette.shadow.opacity(0.5), radius: 1, y: 1)
            .shadow(color: colorScheme == .dark ? .clear : OriveoTheme.Palette.shadow.opacity(0.5), radius: 9, y: 6)
    }
}

extension View {
    func memoryCard(radius: CGFloat = OriveoTheme.Radius.card, outline: Color? = nil, ring: Bool = false) -> some View {
        modifier(MemoryCardModifier(radius: radius, outline: outline, ring: ring))
    }
}

/// Group heading: glyph (hue) + group name + brand-colored count + trailing action.
struct MemoryGroupHeader<Trailing: View>: View {
    let glyph: MemoryGlyph.Kind
    let hue: Color
    let title: String
    let count: Int
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            MemoryGlyph(kind: glyph, size: 18)
                .foregroundStyle(hue)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(OriveoTheme.Palette.textPrimary)
            Text(verbatim: "\(count)")
                .font(OriveoTheme.Typography.brandDigits(13))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
            Spacer(minLength: 8)
            trailing()
        }
        .frame(minHeight: 32)
        .padding(.leading, 4)
        .padding(.trailing, -6)
        .accessibilityElement(children: .combine)
    }
}

struct MemoryGroupAddLabel: View {
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
            .accessibilityLabel(L10n.tr("memory_add_item", table: .chat))
    }
}

/// Horizontal ... at the row end (always visible); tapping opens the system menu.
struct MemoryMoreMenu<MenuContent: View>: View {
    @ViewBuilder let content: () -> MenuContent

    var body: some View {
        Menu {
            content()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(OriveoTheme.Palette.textTertiary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.tr("More", table: .chat))
    }
}

struct MemoryPinMark: View {
    let hue: Color

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hue)
            .accessibilityLabel(L10n.tr("memory_item_pinned_a11y", table: .chat))
    }
}

/// Chip background color ("Paused", scope).
enum MemoryTag {
    static var fill: Color { OriveoTheme.Palette.border }
}

struct MemoryPausedTag: View {
    var body: some View {
        Text(L10n.tr("memory_item_paused_badge", table: .chat))
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(OriveoTheme.Palette.textTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(MemoryTag.fill))
            .fixedSize()
    }
}

/// L3 scope chip: folder / globe / bubble icon + text.
struct MemoryScopeTag: View {
    let scope: MemoryScopeType
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .foregroundStyle(OriveoTheme.Palette.textSecondary)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(MemoryTag.fill))
    }

    private var icon: String {
        switch scope {
        case .global: "globe"
        case .folder: "folder"
        case .conversation: "bubble.left"
        }
    }
}

struct MemoryRowDivider: View {
    let inset: CGFloat

    var body: some View {
        Rectangle()
            .fill(OriveoTheme.Palette.border)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

/// Page footnote: small icon + 13pt footnote color.
struct MemoryFootnote: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(OriveoTheme.Palette.textDisabledOnControl)
        .padding(.horizontal, 6)
    }
}

/// Capsule button: solid (primary) or light purple (secondary).
struct MemoryPillButtonStyle: ButtonStyle {
    var filled: Bool
    var height: CGFloat = 32
    var fontSize: CGFloat = 13.5

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(filled ? OriveoTheme.Palette.onPrimary : OriveoTheme.Palette.primaryTextSafe)
            .padding(.horizontal, 14)
            .frame(minHeight: height)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? OriveoTheme.Palette.primaryTextSafe : OriveoTheme.Palette.primarySoft)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .fixedSize()
    }
}

/// One row of a conflict fork: the left 36pt slot draws the node (solid = this device / newer, hollow = the other device / older; L3 uses a diamond) and the connector line.
struct MemoryForkRow<Eyebrow: View, Content: View, Action: View>: View {
    let isPrimary: Bool
    let isDiamond: Bool
    let linksUp: Bool
    let linksDown: Bool
    let showsDivider: Bool
    @ViewBuilder let eyebrow: () -> Eyebrow
    @ViewBuilder let content: () -> Content
    @ViewBuilder let action: () -> Action

    private static var nodeTop: CGFloat { 20 }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                eyebrow()
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(0.46)
                    .foregroundStyle(OriveoTheme.Palette.textTertiary)
                content()
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            action()
        }
        .padding(.leading, 36)
        .padding(.trailing, 12)
        .padding(.vertical, 14)
        .background(alignment: .topLeading) { slot }
        .overlay(alignment: .top) {
            if showsDivider { MemoryRowDivider(inset: 16) }
        }
    }

    private var slot: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(linksUp ? OriveoTheme.Palette.warningLine : .clear)
                    .frame(width: 1, height: Self.nodeTop + 5)
                Rectangle()
                    .fill(linksDown ? OriveoTheme.Palette.warningLine : .clear)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
            }
            .padding(.leading, 17.5)

            node
                .padding(.leading, isDiamond ? 13.5 : 13)
                .padding(.top, Self.nodeTop)
        }
        .frame(width: 36, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var node: some View {
        if isDiamond {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isPrimary ? OriveoTheme.Palette.warning : OriveoTheme.Palette.surface)
                .overlay {
                    if !isPrimary {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(OriveoTheme.Palette.warning, lineWidth: 2)
                    }
                }
                .frame(width: 9, height: 9)
                .rotationEffect(.degrees(45))
        } else {
            Circle()
                .fill(isPrimary ? OriveoTheme.Palette.warning : OriveoTheme.Palette.surface)
                .overlay {
                    if !isPrimary {
                        Circle().strokeBorder(OriveoTheme.Palette.warning, lineWidth: 2)
                    }
                }
                .frame(width: 10, height: 10)
        }
    }
}

/// Dimensions of the L3 timeline: left 58pt date column + 16pt track + 12pt gap, with body text starting at 86pt.
enum MemoryTimeline {
    static let dateWidth: CGFloat = 58
    static let railWidth: CGFloat = 16
    static let textInset: CGFloat = dateWidth + railWidth + 12

    /// `YYYY-MM-DD` to ("MM·DD", "YYYY"); nil when there is no date.
    static func dateParts(_ day: String) -> (monthDay: String, year: String)? {
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return nil }
        return ("\(parts[1])·\(parts[2])", String(parts[0]))
    }
}

/// Timeline track: a 1pt vertical line runs through the rows (the first row starts at the marker); decision = solid diamond, event = hollow ring.
struct MemoryTimelineRail: View {
    let isFirst: Bool
    let isEvent: Bool
    let isPaused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(OriveoTheme.Palette.borderStrong)
                .frame(width: 1)
                .padding(.top, isFirst ? 22 : 0)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.leading, 7.5)

            Group {
                if isEvent {
                    Circle()
                        .fill(OriveoTheme.Palette.surface)
                        .overlay(Circle().strokeBorder(OriveoTheme.Palette.memoryHue.episodic, lineWidth: 2))
                        .frame(width: 10, height: 10)
                        .padding(.leading, 3)
                } else {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(OriveoTheme.Palette.memoryHue.episodic)
                        .frame(width: 9, height: 9)
                        .rotationEffect(.degrees(45))
                        .padding(.leading, 3.5)
                }
            }
            .padding(.top, 18)
            .opacity(isPaused ? 0.4 : 1)
        }
        .frame(width: MemoryTimeline.railWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.leading, MemoryTimeline.dateWidth)
        .accessibilityHidden(true)
    }
}

/// Composition spectrum: the four groups' counts as proportional segments (3pt gaps, 6pt rounded ends) + a two-column legend; below the dashed line the total of "Events and decisions" is listed on its own.
struct MemorySpectrum: View {
    let sections: [MemoryItemSection]
    let episodicCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !sections.isEmpty {
                bar
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(sections) { section in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(section.group.hue)
                                .frame(width: 8, height: 8)
                            Text(section.group.title)
                                .font(.system(size: 13))
                                .foregroundStyle(OriveoTheme.Palette.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(verbatim: "\(section.rows.count)")
                                .font(OriveoTheme.Typography.brandDigits(13))
                                .foregroundStyle(OriveoTheme.Palette.textPrimary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if episodicCount > 0 {
                VStack(spacing: 12) {
                    if !sections.isEmpty {
                        Line()
                            .stroke(OriveoTheme.Palette.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(height: 1)
                    }
                    HStack(spacing: 8) {
                        MemoryGlyph(kind: .diamond, size: 12)
                            .foregroundStyle(OriveoTheme.Palette.memoryHue.episodic)
                        Text(L10n.tr("memory_group_episodic", table: .chat))
                            .font(.system(size: 13))
                            .foregroundStyle(OriveoTheme.Palette.textSecondary)
                        Spacer(minLength: 4)
                        Text(verbatim: "\(episodicCount)")
                            .font(OriveoTheme.Typography.brandDigits(13))
                            .foregroundStyle(OriveoTheme.Palette.textPrimary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var bar: some View {
        GeometryReader { geometry in
            let total = max(1, sections.reduce(0) { $0 + $1.rows.count })
            let gaps = CGFloat(max(0, sections.count - 1)) * 3
            let usable = max(0, geometry.size.width - gaps)
            HStack(spacing: 3) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    let first = index == 0
                    let last = index == sections.count - 1
                    UnevenRoundedRectangle(
                        topLeadingRadius: first ? 6 : 3,
                        bottomLeadingRadius: first ? 6 : 3,
                        bottomTrailingRadius: last ? 6 : 3,
                        topTrailingRadius: last ? 6 : 3,
                        style: .continuous
                    )
                    .fill(section.group.hue)
                    .frame(width: usable * CGFloat(section.rows.count) / CGFloat(total))
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}
