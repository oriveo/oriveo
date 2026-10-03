/**
 * Value types and protocol constants of the remote MCP client (identical on iOS, Android and web).
 *
 * Test fixtures shared by all clients live in `shared/test-fixtures/mcp/`; behaviour matches the iOS
 * `Core/MCP/McpModels.swift`. This directory is pure logic: it never touches the window / fetch / crypto
 * globals; networking goes through an injected transport (`mcp-transport.ts`), randomness through an
 * injected port.
 */

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

/** The sign-in method chosen by the user. */
export type McpAuthKind = 'auto' | 'token';

/** Negotiated protocol generation. `stateless` = 2026-07-28 and later; `session` = legacy handshake + session. */
export type McpProtocolGeneration = 'stateless' | 'session';

/** Connection status. */
export type McpConnectionStatus = 'connected' | 'needsAuth' | 'unreachable' | 'unknown';

/** Tool permission. */
export type McpToolPermission = 'auto' | 'ask' | 'off';

/** Tools declared read-only default to "run automatically"; everything else (including undeclared) to "ask every time". */
export function defaultPermissionFor(readOnly: boolean): McpToolPermission {
  return readOnly ? 'auto' : 'ask';
}

/** Kind of a tool change. */
export type McpToolChangeKind = 'added' | 'changed' | 'removed';

/**
 * Closed set of error codes. This one set is what is fed back to the model, written to
 * `toolSteps.errorCode` and used for analytics; it **never carries the server's own text**.
 */
export const MCP_ERROR_CODES = [
  'user_denied',
  'needs_auth',
  'auth_skipped',
  'timeout',
  'unreachable',
  'server_error',
  'tool_error',
  'result_too_large',
  'needs_input_unsupported',
  'tool_unavailable',
  'cancelled',
  'interrupted',
] as const;
export type McpErrorCode = (typeof MCP_ERROR_CODES)[number];

// ── Server record ────────────────────────────────────────────────────────

export const MCP_SERVER_MAX_NAME_LENGTH = 64;
export const MCP_SERVER_MAX_URL_LENGTH = 2048;
export const MCP_SERVER_SCHEMA_VERSION = 1;

/**
 * A stored server record. **It has no credential field at all** (credentials only go through
 * `McpCredentialStore`). Timestamps are milliseconds.
 */
export interface McpServerRecord {
  /** Lowercase UUID. */
  id: string;
  name: string;
  slug: string;
  url: string;
  authKind: McpAuthKind;
  iconURL: string | null;
  createdAt: number;
  updatedAt: number;
  schemaVersion: number;
}

// ── Runtime configuration ────────────────────────────────────────────────

export interface McpRuntimeConfig {
  version: number;
  enabled: boolean;
  maxServers: number;
  maxToolsPerRequest: number;
  maxToolDefinitionBytes: number;
  maxResultChars: number;
  callTimeoutSeconds: number;
  maxSteps: number;
}

/** Fallback values used when the model catalog carries no MCP configuration, or cannot be fetched. */
export const MCP_RUNTIME_CONFIG_FALLBACK: Readonly<McpRuntimeConfig> = Object.freeze({
  version: 1,
  enabled: true,
  maxServers: 20,
  maxToolsPerRequest: 40,
  maxToolDefinitionBytes: 16_384,
  maxResultChars: 24_000,
  callTimeoutSeconds: 60,
  maxSteps: 6,
});

/**
 * Allowed range of each numeric field (same as iOS `McpRuntimeConfig.Bounds`). A delivered value outside
 * its range is clamped to the bound: one mistyped number in the configuration should neither disable the
 * feature altogether (a limit of 0 = no server can be added) nor remove a protective limit.
 */
export const MCP_RUNTIME_CONFIG_BOUNDS = Object.freeze({
  maxServers: [1, 100],
  maxToolsPerRequest: [1, 128],
  maxToolDefinitionBytes: [1_024, 262_144],
  maxResultChars: [1_000, 200_000],
  callTimeoutSeconds: [5, 600],
  maxSteps: [1, 8],
} as const);

function clampNumber(value: unknown, [lo, hi]: readonly [number, number], integer: boolean): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  const bounded = Math.min(Math.max(value, lo), hi);
  return integer ? Math.floor(bounded) : bounded;
}

/**
 * Parses the top-level `mcpRuntimeConfig` of `/api/metadata`. Missing or mistyped fields fall back to
 * the defaults; a missing section returns the fallback; out-of-range numbers are clamped to the bound.
 */
export function parseMcpRuntimeConfig(raw: unknown): McpRuntimeConfig {
  const config: McpRuntimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK };
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return config;
  const root = raw as Record<string, unknown>;
  // The version number is not a quantity, so clamping it is meaningless: only integers ≥ 1 are accepted.
  if (typeof root.version === 'number' && Number.isInteger(root.version) && root.version >= 1) {
    config.version = root.version;
  }
  if (typeof root.enabled === 'boolean') config.enabled = root.enabled;
  const b = MCP_RUNTIME_CONFIG_BOUNDS;
  config.maxServers = clampNumber(root.maxServers, b.maxServers, true) ?? config.maxServers;
  config.maxToolsPerRequest = clampNumber(root.maxToolsPerRequest, b.maxToolsPerRequest, true) ?? config.maxToolsPerRequest;
  config.maxToolDefinitionBytes =
    clampNumber(root.maxToolDefinitionBytes, b.maxToolDefinitionBytes, true) ?? config.maxToolDefinitionBytes;
  config.maxResultChars = clampNumber(root.maxResultChars, b.maxResultChars, true) ?? config.maxResultChars;
  config.callTimeoutSeconds =
    clampNumber(root.callTimeoutSeconds, b.callTimeoutSeconds, false) ?? config.callTimeoutSeconds;
  config.maxSteps = clampNumber(root.maxSteps, b.maxSteps, true) ?? config.maxSteps;
  return config;
}

/** Step limit: the smaller of the two, consistent with the generic loop (default 6, at most 8). */
export function effectiveMaxSteps(config: McpRuntimeConfig): number {
  return Math.min(config.maxSteps, 8);
}

// ── Tool definitions and snapshots ───────────────────────────────────────

/**
 * One tool returned by the server (an item of `tools[]` in `tools/list`). Everything in `annotations`
 * is a self-reported third-party hint and is treated as untrusted. `inputSchema` keeps the original
 * property order given by the server (the argument summary is taken in that order).
 */
export interface McpToolDefinition {
  name: string;
  title: string | null;
  description: string | null;
  inputSchema: JsonValue;
  annotations: JsonValue;
}

/** Display name precedence: `title` → `annotations.title` → `name`. */
export function toolDisplayTitle(definition: Pick<McpToolDefinition, 'name' | 'title' | 'annotations'>): string {
  if (definition.title) return definition.title;
  const annotations = definition.annotations;
  if (annotations && typeof annotations === 'object' && !Array.isArray(annotations)) {
    const title = annotations.title;
    if (typeof title === 'string' && title.length > 0) return title;
  }
  return definition.name;
}

/** Read-only declaration. Missing = undeclared = treated as modifying data. */
export function toolReadOnly(definition: Pick<McpToolDefinition, 'annotations'>): boolean {
  const annotations = definition.annotations;
  if (!annotations || typeof annotations !== 'object' || Array.isArray(annotations)) return false;
  return annotations.readOnlyHint === true;
}

/** Builds a definition from a single tool object of `tools/list`; an entry without `name` is invalid and skipped. */
export function parseToolDefinition(raw: unknown): McpToolDefinition | null {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null;
  const json = raw as Record<string, JsonValue>;
  if (typeof json.name !== 'string' || json.name.length === 0) return null;
  return {
    name: json.name,
    title: typeof json.title === 'string' ? json.title : null,
    description: typeof json.description === 'string' ? json.description : null,
    inputSchema: json.inputSchema ?? {},
    annotations: json.annotations ?? {},
  };
}

/**
 * Tool snapshot: `serverId` + original tool name → title, description, parameter definition, read-only
 * declaration, content hash, quarantined, unusable because oversized.
 */
export interface McpToolSnapshot {
  serverId: string;
  toolName: string;
  title: string;
  description: string | null;
  inputSchema: JsonValue;
  annotations: JsonValue;
  contentHash: string;
  readOnly: boolean;
  pendingReview: boolean;
  oversized: boolean;
  updatedAt: number;
}

/** One tool change. */
export interface McpToolChange {
  kind: McpToolChangeKind;
  toolName: string;
  title: string;
}

/**
 * Connection state record. The legacy protocol's session identifier is kept in memory and in this
 * record only and never logged.
 */
export interface McpConnectionState {
  serverId: string;
  status: McpConnectionStatus;
  lastSuccessAt: number | null;
  negotiatedVersion: string | null;
  generation: McpProtocolGeneration | null;
  sessionId: string | null;
}

// ── Protocol constants ───────────────────────────────────────────────────

export const MCP_MODERN_VERSION = '2026-07-28';
/** In the legacy handshake the client SHOULD send the latest version it supports. */
export const MCP_LEGACY_INITIALIZE_VERSION = '2025-11-25';
/** The legacy versions we support, newest first (the order used to pick "the highest version both sides support"). */
export const MCP_LEGACY_VERSIONS: readonly string[] = ['2025-11-25', '2025-06-18', '2025-03-26'];
export const MCP_UNSUPPORTED_VERSION_ERROR = -32022;
export const MCP_INVALID_PARAMS_ERROR = -32602;
export const MCP_METHOD_NOT_FOUND_ERROR = -32601;
/** Recognizable modern JSON-RPC error codes: seeing one means the server is modern, so no fallback to initialize. */
export const MCP_MODERN_ERROR_CODES: ReadonlySet<number> = new Set([-32020, -32021, MCP_UNSUPPORTED_VERSION_ERROR]);
/** Identifiers specific to the modern protocol, case-sensitive. */
const MODERN_ERROR_MARKERS = ['io.modelcontextprotocol/', '_meta', 'resultType'];
/**
 * **Request header names** specific to the modern protocol (compared in lowercase). **Excludes
 * `MCP-Protocol-Version` and `Mcp-Session-Id`**: legacy versions use both too, and if they counted as
 * modern markers when they show up in a legacy server's error text, such a server would never fall back
 * to initialize.
 */
const MODERN_HEADER_MARKERS = ['mcp-method', 'mcp-name', 'mcp-param-'];

export function containsModernMarker(text: string): boolean {
  if (MODERN_ERROR_MARKERS.some((marker) => text.includes(marker))) return true;
  const lowered = text.toLowerCase();
  return MODERN_HEADER_MARKERS.some((marker) => lowered.includes(marker));
}

/** Page limit for `tools/list` (a limit this client imposes itself). */
export const MCP_MAX_TOOLS_LIST_PAGES = 20;
export const MCP_META_PROTOCOL_VERSION = 'io.modelcontextprotocol/protocolVersion';
export const MCP_META_CLIENT_INFO = 'io.modelcontextprotocol/clientInfo';
export const MCP_META_CLIENT_CAPABILITIES = 'io.modelcontextprotocol/clientCapabilities';
export const MCP_CLIENT_INFO = Object.freeze({ name: 'Oriveo', version: '1.0.0' });
