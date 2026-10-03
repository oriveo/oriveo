import Foundation

// MARK: - Tool catalog
//
// Consumes the output of `McpClient.listTools()` and produces tool snapshots, default permissions and the list
// of changes. Paging of `tools/list` is already handled in `McpClient`; this unit is only the pure logic that
// runs once the definitions are in hand.
//
// `annotations` (including `readOnlyHint`) are hints self-reported by a third party and are treated as
// untrusted (the MCP specification says clients MUST consider tool annotations to be untrusted): a read-only
// declaration is only used to relax a tool to "run automatically", and anything undeclared is treated as
// modifying data.

nonisolated enum McpToolCatalog {
    /// Whether one tool's "description + input schema" exceeds `maxToolDefinitionBytes`.
    /// A tool over the cap is marked `oversized` and is never sent to the model.
    static func isOversized(_ definition: McpToolDefinition, runtimeConfig: McpRuntimeConfig) -> Bool {
        definitionSizeBytes(definition) > runtimeConfig.maxToolDefinitionBytes
    }

    /// UTF-8 byte count of the description (0 when missing) plus the canonical JSON of the input schema.
    static func definitionSizeBytes(_ definition: McpToolDefinition) -> Int {
        definitionSizeBytes(description: definition.description, inputSchema: definition.inputSchema)
    }

    static func definitionSizeBytes(description: String?, inputSchema: JSONValue) -> Int {
        (description ?? "").utf8.count + inputSchema.canonicalJSONString.utf8.count
    }

    /// Judges whether a stored snapshot is oversized under the **current** runtime config. The `oversized` flag on
    /// the snapshot is the verdict from when it was stored, and the cap comes from the server and can change at any
    /// time: after it is lowered, a tool that "was not too big" in an old snapshot must not go out regardless, and
    /// after it is raised a tool should not stay blocked forever.
    static func isOversized(_ snapshot: McpToolSnapshot, runtimeConfig: McpRuntimeConfig) -> Bool {
        definitionSizeBytes(description: snapshot.description, inputSchema: snapshot.inputSchema)
            > runtimeConfig.maxToolDefinitionBytes
    }

    /// The content hash of one tool: SHA-256 over `name` / `description ?? null` / the canonicalized `inputSchema` /
    /// the canonicalized `annotations ?? {}`.
    static func contentHash(_ definition: McpToolDefinition) -> String {
        McpToolHash.contentHash(
            name: definition.name,
            description: definition.description,
            inputSchema: definition.inputSchema,
            annotations: definition.annotations
        )
    }

    // MARK: - Change detection for a single tool

    /// "This tool changed": its content hash changed, **or** its display title changed.
    ///
    /// The hash input does not include the top-level `title` (frozen by the shared fixture `tool-hash.json`), yet
    /// the title is exactly what the confirmation sheet shows. Looking at the hash alone would let a server rename
    /// an already approved tool from "Search" to "Delete everything" without triggering any confirmation.
    static func isChanged(_ snapshot: McpToolSnapshot, comparedTo definition: McpToolDefinition) -> Bool {
        snapshot.contentHash != contentHash(definition) || snapshot.title != definition.displayTitle
    }

    /// When the server returns tools with the same name only the first one counts (original order is kept). The
    /// snapshot primary key is "server + original tool name", so without de-duplication the whole write would fail
    /// on a key conflict; the model can only have one tool per name anyway.
    static func deduplicated(_ definitions: [McpToolDefinition]) -> [McpToolDefinition] {
        var seen = Set<String>()
        return definitions.filter { seen.insert($0.name).inserted }
    }

    // MARK: - Snapshots

    /// Builds tool snapshots from the `tools/list` output.
    ///
    /// **New or changed tools get `pendingReview = true`** and stay quarantined until the user confirms them.
    /// Unchanged tools keep their existing quarantine flag (one the user has not confirmed yet stays quarantined
    /// and is not quietly released by a refetch).
    static func snapshots(
        serverId: UUID,
        definitions: [McpToolDefinition],
        runtimeConfig: McpRuntimeConfig,
        existing: [McpToolSnapshot] = [],
        now: Date = Date()
    ) -> [McpToolSnapshot] {
        let existingByName = Dictionary(existing.map { ($0.toolName, $0) }, uniquingKeysWith: { first, _ in first })
        return deduplicated(definitions).map { definition in
            let previous = existingByName[definition.name]
            let changed = previous.map { isChanged($0, comparedTo: definition) } ?? true
            return McpToolSnapshot(
                serverId: serverId,
                toolName: definition.name,
                title: definition.displayTitle,
                description: definition.description,
                inputSchema: definition.inputSchema,
                annotations: definition.annotations,
                contentHash: contentHash(definition),
                readOnly: definition.readOnly,
                pendingReview: changed ? true : (previous?.pendingReview ?? true),
                oversized: isOversized(definition, runtimeConfig: runtimeConfig),
                updatedAt: now
            )
        }
    }

    // MARK: - Change detection

    /// Compares the existing snapshots with the new ones and yields three kinds of change: added, changed, removed.
    /// "Changed" is judged exactly like `isChanged`: the content hash or the display title differs.
    static func changes(existing: [McpToolSnapshot], incoming: [McpToolSnapshot]) -> [McpToolChange] {
        let existingByName = Dictionary(existing.map { ($0.toolName, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingNames = Set(incoming.map(\.toolName))

        var result: [McpToolChange] = []
        for snapshot in incoming where existingByName[snapshot.toolName] == nil {
            result.append(McpToolChange(kind: .added, toolName: snapshot.toolName, title: snapshot.title))
        }
        for snapshot in incoming {
            guard let previous = existingByName[snapshot.toolName],
                  previous.contentHash != snapshot.contentHash || previous.title != snapshot.title else { continue }
            result.append(McpToolChange(kind: .changed, toolName: snapshot.toolName, title: snapshot.title))
        }
        for snapshot in existing where !incomingNames.contains(snapshot.toolName) {
            result.append(McpToolChange(kind: .removed, toolName: snapshot.toolName, title: snapshot.title))
        }
        return result
    }

    // MARK: - Default permissions

    /// Tools declared read-only "run automatically"; everything else (including undeclared) is "ask every time".
    static func defaultPermissions(for snapshots: [McpToolSnapshot]) -> [String: McpToolPermission] {
        var result: [String: McpToolPermission] = [:]
        for snapshot in snapshots {
            result[snapshot.toolName] = McpToolPermission.defaultFor(readOnly: snapshot.readOnly)
        }
        return result
    }

    // MARK: - Outbound filtering

    /// The tools sent to the model: quarantined (`pendingReview`), "off" and oversized tools never appear.
    /// A missing permission falls back to the default one (which is never "off").
    ///
    /// With a `runtimeConfig`, "oversized" is re-judged under the current config (request assembly takes this
    /// path); without one, the verdict stored on the snapshot is used.
    static func outboundSnapshots(
        _ snapshots: [McpToolSnapshot],
        permissions: [String: McpToolPermission],
        runtimeConfig: McpRuntimeConfig? = nil
    ) -> [McpToolSnapshot] {
        snapshots.filter { snapshot in
            let oversized = runtimeConfig.map { isOversized(snapshot, runtimeConfig: $0) } ?? snapshot.oversized
            guard !snapshot.pendingReview, !oversized else { return false }
            let permission = permissions[snapshot.toolName]
                ?? McpToolPermission.defaultFor(readOnly: snapshot.readOnly)
            return permission != .off
        }
    }

    // MARK: - Confirming and lifting the quarantine

    /// The user confirms a change: the quarantine is lifted and the updated snapshot returned only when **the
    /// server's current definition still matches the snapshot the user saw** (neither the content hash nor the
    /// display title changed). `nil` means the server changed the tool again during confirmation, so it must stay
    /// quarantined.
    static func confirmed(
        _ snapshot: McpToolSnapshot,
        against definition: McpToolDefinition,
        runtimeConfig: McpRuntimeConfig,
        now: Date = Date()
    ) -> McpToolSnapshot? {
        guard !isChanged(snapshot, comparedTo: definition) else { return nil }
        var updated = snapshot
        updated.pendingReview = false
        updated.oversized = isOversized(definition, runtimeConfig: runtimeConfig)
        updated.updatedAt = now
        return updated
    }

    /// The permission after confirming (permissions only ever go down, never up): a tool without a permission row
    /// (newly added) gets the default; for one with a row, if the confirmed read-only declaration is no longer
    /// `true` while the current permission is "run automatically", it drops to "ask every time". Nothing else moves.
    ///
    /// The drop closes this path: a tool declared read-only, auto-run by default, is later changed by the server
    /// into one that writes data. What the user confirms is "I know it changed", not "it may write data from now on
    /// without asking me". Confirming never loosens a permission.
    static func permissionAfterConfirming(
        _ snapshot: McpToolSnapshot,
        current: McpToolPermission?
    ) -> McpToolPermission {
        guard let current else { return McpToolPermission.defaultFor(readOnly: snapshot.readOnly) }
        if current == .auto && !snapshot.readOnly { return .ask }
        return current
    }

    /// Confirms in bulk. `permissions` are the permissions before confirming; the result holds the snapshots and
    /// permissions after confirming, plus the names of tools that changed again during confirmation and stay
    /// quarantined. Tools the server has removed are kept as is (removal is reported by `changes`, not silently
    /// applied here).
    ///
    /// Permissions are recomputed only for tools that **actually went from quarantined to released this time**;
    /// tools that were not quarantined, or whose confirmation was rejected, are left alone.
    /// The result goes to `McpServerStore.saveToolCatalog`, which stores it in one transaction.
    static func confirm(
        _ snapshots: [McpToolSnapshot],
        definitions: [McpToolDefinition],
        permissions: [String: McpToolPermission],
        runtimeConfig: McpRuntimeConfig,
        now: Date = Date()
    ) -> McpToolConfirmation {
        let definitionsByName = Dictionary(
            definitions.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = McpToolConfirmation(snapshots: [], permissions: permissions, stillPending: [])
        for snapshot in snapshots {
            guard let definition = definitionsByName[snapshot.toolName] else {
                result.snapshots.append(snapshot)
                continue
            }
            guard let confirmed = confirmed(snapshot, against: definition, runtimeConfig: runtimeConfig, now: now) else {
                result.stillPending.append(snapshot.toolName)
                result.snapshots.append(snapshot)
                continue
            }
            result.snapshots.append(confirmed)
            if snapshot.pendingReview {
                result.permissions[snapshot.toolName] = permissionAfterConfirming(
                    confirmed, current: permissions[snapshot.toolName]
                )
            }
        }
        return result
    }
}

/// The result of one bulk confirmation (`McpToolCatalog.confirm`).
nonisolated struct McpToolConfirmation: Sendable, Equatable {
    var snapshots: [McpToolSnapshot]
    /// All permissions after confirming (those from before plus the ones recomputed this time).
    var permissions: [String: McpToolPermission]
    /// Names of the tools the server changed again during confirmation and that stay quarantined.
    var stillPending: [String]
}
