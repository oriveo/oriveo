/**
 * Pure functions for the MCP UI: tools panel rows and estimates, argument rows of the confirmation
 * dialog, and step block titles. They touch neither the store nor the DOM; components only render
 * what these return.
 */

import {
  isJsonObject,
  maskSecretPathSegments,
  outboundToolSnapshots,
  planMcpTools,
  type JsonObject,
  type JsonValue,
  type McpConnectionState,
  type McpRuntimeConfig,
  type McpServerRecord,
  type McpToolPermission,
  type McpToolPlan,
  type McpToolSnapshot,
} from '@oriveo/core/mcp/index';
import type { McpBridgeServerInput } from '@oriveo/core/mcp/index';

// ── Tools panel ─────────────────────────────────────────────────────────

export type McpPanelRowStatus = 'ready' | 'needsAuth' | 'unreachable';

export interface McpPanelRow {
  server: McpServerRecord;
  status: McpPanelRowStatus;
  /** Number of tools that will be sent to the model (excluding disabled, quarantined and oversized ones). */
  toolCount: number;
  /** Some tools are quarantined until the user reviews their changes. */
  hasPendingReview: boolean;
  enabled: boolean;
  lastSuccessAt: number | null;
}

export interface McpPanelModel {
  rows: McpPanelRow[];
  /** The number on the pill: servers enabled for this conversation that are usable. */
  enabledCount: number;
  /** Number of tools the next request will carry (after truncation). */
  toolCount: number;
  /** Estimated tokens of the tool definitions; 0 when there are no tools. */
  estimatedTokens: number;
  truncated: boolean;
}

export function buildMcpPanelModel(input: {
  servers: readonly McpServerRecord[];
  snapshots: Readonly<Record<string, readonly McpToolSnapshot[]>>;
  permissions: Readonly<Record<string, Readonly<Record<string, McpToolPermission>>>>;
  connections: Readonly<Record<string, McpConnectionState>>;
  enabledServerIds: readonly string[];
  runtimeConfig: McpRuntimeConfig;
}): McpPanelModel {
  const enabled = new Set(input.enabledServerIds);
  const rows = input.servers.map((server): McpPanelRow => {
    const snapshots = input.snapshots[server.id] ?? [];
    const connection = input.connections[server.id];
    const status: McpPanelRowStatus =
      connection?.status === 'needsAuth' ? 'needsAuth' : connection?.status === 'unreachable' ? 'unreachable' : 'ready';
    return {
      server,
      status,
      toolCount: outboundToolSnapshots(snapshots, input.permissions[server.id] ?? {}).length,
      hasPendingReview: snapshots.some((snapshot) => snapshot.pendingReview),
      enabled: enabled.has(server.id),
      lastSuccessAt: connection?.lastSuccessAt ?? null,
    };
  });
  // Same assembly function and same order as the send path, so the numbers on the panel are exactly
  // what the next request will carry.
  const bridgeInputs: McpBridgeServerInput[] = [];
  for (const serverId of input.enabledServerIds) {
    const record = input.servers.find((server) => server.id === serverId);
    if (!record) continue;
    bridgeInputs.push({
      record,
      connectionStatus: input.connections[serverId]?.status ?? null,
      snapshots: [...(input.snapshots[serverId] ?? [])].sort((a, b) => (a.toolName < b.toolName ? -1 : a.toolName > b.toolName ? 1 : 0)),
      permissions: input.permissions[serverId] ?? {},
    });
  }
  const plan = planMcpTools(bridgeInputs, input.runtimeConfig);
  return {
    rows,
    enabledCount: rows.filter((row) => row.enabled && row.status === 'ready').length,
    toolCount: plan.tools.length,
    estimatedTokens: estimateMcpToolTokens(plan),
    truncated: plan.truncated,
  };
}

/**
 * Token estimate: the serialized character count of the available tool definitions divided by 4,
 * rounded to the nearest hundred. This is an estimate, not a measurement; with any tool present it
 * reports at least 100 rather than "about 0".
 */
export function estimateMcpToolTokens(plan: Pick<McpToolPlan, 'tools'>): number {
  if (plan.tools.length === 0) return 0;
  const characters = plan.tools.reduce((total, tool) => total + JSON.stringify(tool.definition).length, 0);
  return Math.max(100, Math.round(characters / 4 / 100) * 100);
}

// ── Confirmation dialog ─────────────────────────────────────────────────

/** A string argument longer than this is not shown in full in the dialog; it becomes "about N characters · view full text". */
export const MCP_CONFIRM_LONG_TEXT_THRESHOLD = 120;
export const MCP_CONFIRM_MAX_ROWS = 4;

export interface McpConfirmationRow {
  /** The argument name exactly as the server defines it (never translated). */
  key: string;
  /** Short values are shown directly; null for long text, where the UI shows the length and a "view full text" link. */
  value: string | null;
  /** Length of the text in characters (counted by code point). */
  length: number;
  /** The full content (for the full-text view). */
  full: string;
}

function displayValue(value: JsonValue): string {
  if (typeof value === 'string') return value;
  return JSON.stringify(value);
}

/**
 * The first 4 top-level arguments. They follow the original order of `properties` in the server's
 * input schema; arguments missing from the schema come after, in the order the model gave them.
 */
export function mcpConfirmationRows(args: JsonObject, inputSchema: JsonValue): McpConfirmationRow[] {
  const properties = isJsonObject(inputSchema) && isJsonObject(inputSchema.properties) ? Object.keys(inputSchema.properties) : [];
  const ordered = [...properties.filter((key) => Object.hasOwn(args, key)), ...Object.keys(args).filter((key) => !properties.includes(key))];
  return ordered.slice(0, MCP_CONFIRM_MAX_ROWS).map((key) => {
    const full = displayValue(args[key] as JsonValue);
    const length = Array.from(full).length;
    return { key, value: length > MCP_CONFIRM_LONG_TEXT_THRESHOLD ? null : full, length, full };
  });
}

/** Number of arguments the model supplied that did not fit in the first 4 rows. */
export function mcpConfirmationHiddenCount(args: JsonObject): number {
  return Math.max(0, Object.keys(args).length - MCP_CONFIRM_MAX_ROWS);
}

/** Content of the full-text view: every argument, listed as is under its original key name. */
export function mcpConfirmationFullText(args: JsonObject): Array<{ key: string; text: string }> {
  return Object.keys(args).map((key) => {
    const value = args[key] as JsonValue;
    return { key, text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) };
  });
}

// ── Helpers for step details and the management page ────────────────────

/** Duration: milliseconds below 1 second, otherwise seconds with one decimal place. */
export function mcpDurationParts(durationMs: number): { unit: 'ms' | 's'; value: number } {
  if (durationMs < 1000) return { unit: 'ms', value: Math.max(0, Math.round(durationMs)) };
  return { unit: 's', value: Math.round(durationMs / 100) / 10 };
}

/**
 * Display form of a server address: scheme removed, host and path kept. Whatever may carry a
 * secret is not shown: the query string and userinfo are dropped, and a path segment that looks
 * like a key is replaced by `…`.
 */
export function mcpDisplayAddress(url: string): string {
  try {
    const parsed = new URL(url);
    const path = parsed.pathname === '/' ? '' : maskSecretPathSegments(parsed.pathname);
    return `${parsed.host}${path}`;
  } catch {
    return url;
  }
}

export function mcpHostname(url: string): string {
  try {
    return new URL(url).hostname;
  } catch {
    return url;
  }
}

/** The letter on the initial tile, used when the server has no icon of its own. */
export function mcpServerInitial(name: string): string {
  const first = Array.from(name.trim())[0];
  return first ? first.toUpperCase() : '?';
}
