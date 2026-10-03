/**
 * Tool catalog.
 *
 * Consumes the output of `McpClient.listTools()` and produces tool snapshots, default permissions and the
 * list of changes. `annotations` (including `readOnlyHint`) are hints self-reported by a third party and
 * are treated as untrusted: a read-only declaration is only used to relax a tool to "run automatically",
 * and a tool without one is always treated as one that modifies data.
 */

import { canonicalJsonString, toolContentHash, utf8Bytes } from './mcp-pure';
import {
  defaultPermissionFor,
  toolDisplayTitle,
  toolReadOnly,
  type McpRuntimeConfig,
  type McpToolChange,
  type McpToolDefinition,
  type McpToolPermission,
  type McpToolSnapshot,
} from './mcp-types';

/** UTF-8 byte count of the description (0 when missing) plus the canonical JSON of the parameter definition. */
export function toolDefinitionSizeBytes(definition: Pick<McpToolDefinition, 'description' | 'inputSchema'>): number {
  return utf8Bytes(definition.description ?? '').length + utf8Bytes(canonicalJsonString(definition.inputSchema)).length;
}

/** A tool whose "description + parameter definition" exceeds `maxToolDefinitionBytes` is oversized and is never sent to the model. */
export function isToolOversized(definition: Pick<McpToolDefinition, 'description' | 'inputSchema'>, config: McpRuntimeConfig): boolean {
  return toolDefinitionSizeBytes(definition) > config.maxToolDefinitionBytes;
}

export function definitionContentHash(definition: McpToolDefinition): string {
  return toolContentHash(definition);
}

/**
 * "This tool changed": the content hash changed, **or** the display title changed. The hash does not cover
 * the top-level `title` (frozen by the fixtures), yet the title is exactly what the confirmation dialog
 * shows - looking at the hash alone, a server could retitle an approved tool from "Search" to
 * "Delete everything" without triggering any confirmation.
 */
export function isToolChanged(snapshot: Pick<McpToolSnapshot, 'contentHash' | 'title'>, definition: McpToolDefinition): boolean {
  return snapshot.contentHash !== definitionContentHash(definition) || snapshot.title !== toolDisplayTitle(definition);
}

/** When the server returns tools with the same name, only the first one counts (order preserved) instead of failing the whole add. */
export function deduplicateTools(definitions: readonly McpToolDefinition[]): McpToolDefinition[] {
  const seen = new Set<string>();
  return definitions.filter((definition) => {
    if (seen.has(definition.name)) return false;
    seen.add(definition.name);
    return true;
  });
}

/**
 * Builds snapshots from the `tools/list` output. **New or changed tools get `pendingReview = true`** and stay
 * quarantined until the user confirms them; unchanged tools keep their existing quarantine flag (one that was
 * never confirmed stays quarantined instead of being quietly released by a refetch). `inputSchema` keeps its
 * original property order (the argument summary relies on it); canonical JSON is used only for hashing.
 */
export function buildToolSnapshots(input: {
  serverId: string;
  definitions: readonly McpToolDefinition[];
  runtimeConfig: McpRuntimeConfig;
  existing?: readonly McpToolSnapshot[];
  now?: number;
}): McpToolSnapshot[] {
  const existing = new Map<string, McpToolSnapshot>();
  for (const snapshot of input.existing ?? []) if (!existing.has(snapshot.toolName)) existing.set(snapshot.toolName, snapshot);
  const now = input.now ?? Date.now();
  return deduplicateTools(input.definitions).map((definition) => {
    const previous = existing.get(definition.name);
    const changed = previous ? isToolChanged(previous, definition) : true;
    return {
      serverId: input.serverId,
      toolName: definition.name,
      title: toolDisplayTitle(definition),
      description: definition.description,
      inputSchema: definition.inputSchema,
      annotations: definition.annotations,
      contentHash: definitionContentHash(definition),
      readOnly: toolReadOnly(definition),
      pendingReview: changed ? true : (previous?.pendingReview ?? true),
      oversized: isToolOversized(definition, input.runtimeConfig),
      updatedAt: now,
    };
  });
}

/** Compares the existing snapshots with the new ones and yields "added / changed / removed" (same criterion as `isToolChanged`). */
export function diffToolSnapshots(existing: readonly McpToolSnapshot[], incoming: readonly McpToolSnapshot[]): McpToolChange[] {
  const before = new Map<string, McpToolSnapshot>();
  for (const snapshot of existing) if (!before.has(snapshot.toolName)) before.set(snapshot.toolName, snapshot);
  const incomingNames = new Set(incoming.map((snapshot) => snapshot.toolName));
  const result: McpToolChange[] = [];
  for (const snapshot of incoming) {
    if (!before.has(snapshot.toolName)) result.push({ kind: 'added', toolName: snapshot.toolName, title: snapshot.title });
  }
  for (const snapshot of incoming) {
    const previous = before.get(snapshot.toolName);
    if (previous && (previous.contentHash !== snapshot.contentHash || previous.title !== snapshot.title)) {
      result.push({ kind: 'changed', toolName: snapshot.toolName, title: snapshot.title });
    }
  }
  for (const snapshot of existing) {
    if (!incomingNames.has(snapshot.toolName)) result.push({ kind: 'removed', toolName: snapshot.toolName, title: snapshot.title });
  }
  return result;
}

/** Tools declared read-only default to "run automatically"; everything else (including tools with no declaration) to "ask every time". */
export function defaultToolPermissions(snapshots: readonly McpToolSnapshot[]): Record<string, McpToolPermission> {
  const result: Record<string, McpToolPermission> = {};
  for (const snapshot of snapshots) result[snapshot.toolName] = defaultPermissionFor(snapshot.readOnly);
  return result;
}

/**
 * The tools sent to the model: quarantined tools, tools whose permission is "do not use" and oversized
 * tools are all left out. A missing permission falls back to the default (which is never "do not use").
 */
export function outboundToolSnapshots(
  snapshots: readonly McpToolSnapshot[],
  permissions: Readonly<Record<string, McpToolPermission>>,
): McpToolSnapshot[] {
  return snapshots.filter((snapshot) => {
    if (snapshot.pendingReview || snapshot.oversized) return false;
    const permission = permissions[snapshot.toolName] ?? defaultPermissionFor(snapshot.readOnly);
    return permission !== 'off';
  });
}

/**
 * The user confirms a change: the quarantine is lifted only if the server's current definition still matches
 * the snapshot the user saw (neither the hash nor the display title changed); `null` means the server
 * changed it again during confirmation, so the tool must stay quarantined.
 */
export function confirmToolSnapshot(
  snapshot: McpToolSnapshot,
  definition: McpToolDefinition,
  config: McpRuntimeConfig,
  now: number = Date.now(),
): McpToolSnapshot | null {
  if (isToolChanged(snapshot, definition)) return null;
  return { ...snapshot, pendingReview: false, oversized: isToolOversized(definition, config), updatedAt: now };
}

/**
 * Permission after confirmation (permissions only ever tighten): a tool without a record (newly added) takes
 * the default; for a tool with a record, when the confirmed read-only declaration is no longer `true` and the
 * current permission is "run automatically", it drops back to "ask every time", and nothing else changes.
 * The user confirmed "I know it changed", not "it may write data from now on without asking me".
 */
export function permissionAfterConfirming(snapshot: Pick<McpToolSnapshot, 'readOnly'>, current: McpToolPermission | undefined): McpToolPermission {
  if (current === undefined) return defaultPermissionFor(snapshot.readOnly);
  if (current === 'auto' && !snapshot.readOnly) return 'ask';
  return current;
}

export interface McpToolConfirmation {
  snapshots: McpToolSnapshot[];
  /** All permissions after confirmation (those from before plus the ones recomputed this time). */
  permissions: Record<string, McpToolPermission>;
  /** Names of tools the server changed again during confirmation and that therefore stay quarantined. */
  stillPending: string[];
}

/**
 * Bulk confirmation. Permissions are recomputed only for tools that **actually went from quarantined to
 * released this time**; tools the server has removed are kept as they are (removal is reported by
 * `diffToolSnapshots`, never silently deleted here). The result is handed to storage to be saved in one transaction.
 */
export function confirmToolSnapshots(input: {
  snapshots: readonly McpToolSnapshot[];
  definitions: readonly McpToolDefinition[];
  permissions: Readonly<Record<string, McpToolPermission>>;
  runtimeConfig: McpRuntimeConfig;
  now?: number;
}): McpToolConfirmation {
  const byName = new Map<string, McpToolDefinition>();
  for (const definition of input.definitions) if (!byName.has(definition.name)) byName.set(definition.name, definition);
  const result: McpToolConfirmation = { snapshots: [], permissions: { ...input.permissions }, stillPending: [] };
  for (const snapshot of input.snapshots) {
    const definition = byName.get(snapshot.toolName);
    if (!definition) {
      result.snapshots.push(snapshot);
      continue;
    }
    const confirmed = confirmToolSnapshot(snapshot, definition, input.runtimeConfig, input.now);
    if (!confirmed) {
      result.stillPending.push(snapshot.toolName);
      result.snapshots.push(snapshot);
      continue;
    }
    result.snapshots.push(confirmed);
    if (snapshot.pendingReview) {
      result.permissions[snapshot.toolName] = permissionAfterConfirming(confirmed, input.permissions[snapshot.toolName]);
    }
  }
  return result;
}
