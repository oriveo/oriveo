/**
 * MCP telemetry. Every field is a closed-set enum or a number: events carry **no** server address
 * or hostname, server name, tool name, arguments, results or raw error text. Event objects are
 * built only here, so callers cannot pass in any other field.
 */

import type {
  McpAddState,
  McpAuthKind,
  McpConfirmationChoice,
  McpProtocolGeneration,
  McpToolChange,
  McpToolStepUpdate,
} from '@oriveo/core/mcp/index';
import { trackEvent } from '../telemetry';

// ── mcp_tool_call ───────────────────────────────────────────────────────

export type McpDurationBucket = 'lt_1s' | '1_5s' | '5_15s' | '15_60s' | 'gte_60s' | 'none';

export function mcpDurationBucket(durationMs: number | null | undefined): McpDurationBucket {
  if (durationMs == null || !Number.isFinite(durationMs)) return 'none';
  if (durationMs < 1_000) return 'lt_1s';
  if (durationMs < 5_000) return '1_5s';
  if (durationMs < 15_000) return '5_15s';
  if (durationMs < 60_000) return '15_60s';
  return 'gte_60s';
}

export function mcpToolCallEvent(update: Pick<McpToolStepUpdate, 'status' | 'errorCode' | 'permission' | 'readOnly' | 'durationMs'>) {
  return {
    status: update.status,
    errorCode: update.errorCode ?? 'none',
    permission: update.permission,
    durationBucket: mcpDurationBucket(update.durationMs),
    readOnly: update.readOnly,
  };
}

/** A step reached a terminal state. */
export function reportMcpToolCall(update: McpToolStepUpdate): void {
  trackEvent('mcp_tool_call', mcpToolCallEvent(update));
}

// ── mcp_confirm_choice ──────────────────────────────────────────────────

/** The user made a choice in the confirmation dialog (ending because the user pressed stop does not count). */
export function reportMcpConfirmChoice(choice: McpConfirmationChoice): void {
  trackEvent('mcp_confirm_choice', { choice });
}

// ── mcp_server_add_result ───────────────────────────────────────────────

export type McpAddOutcome =
  | 'added'
  | 'invalid_url'
  | 'unreachable'
  | 'not_mcp'
  | 'needs_token'
  | 'token_rejected'
  | 'auth_cancelled'
  | 'auth_failed'
  | 'limit_reached'
  | 'cancelled'
  | 'save_failed';

const ADD_OUTCOMES: Record<McpAddState['kind'], McpAddOutcome | null> = {
  connecting: null,
  authPrompt: null,
  browser: null,
  finishing: null,
  review: 'added',
  invalidURL: 'invalid_url',
  unreachable: 'unreachable',
  notMcp: 'not_mcp',
  needsToken: 'needs_token',
  tokenRejected: 'token_rejected',
  authCancelled: 'auth_cancelled',
  limitReached: 'limit_reached',
  cancelled: 'cancelled',
  saveFailed: 'save_failed',
};

export function mcpServerAddResultEvent(state: McpAddState, authKind: McpAuthKind) {
  const outcome = ADD_OUTCOMES[state.kind];
  if (!outcome) return null;
  const protocolGeneration: McpProtocolGeneration | 'none' = state.kind === 'review' ? state.review.session.generation : 'none';
  return { outcome, authKind, protocolGeneration };
}

/** The add-server flow ended in a terminal state. In-progress states are not reported. */
export function reportMcpServerAddResult(state: McpAddState, authKind: McpAuthKind): void {
  const event = mcpServerAddResultEvent(state, authKind);
  if (event) trackEvent('mcp_server_add_result', event);
}

// ── mcp_auth_result ─────────────────────────────────────────────────────

export type McpAuthTrigger = 'add' | 'reauth' | 'mid_loop';
export type McpAuthOutcome = 'connected' | 'cancelled' | 'unreachable' | 'failed' | 'gone';

export function mcpAuthResultEvent(input: { outcome: McpAuthOutcome; registration: 'cimd' | 'dcr' | 'none'; trigger: McpAuthTrigger }) {
  return {
    outcome: input.outcome === 'connected' ? 'success' : input.outcome === 'gone' ? 'failed' : input.outcome,
    registration: input.registration,
    trigger: input.trigger,
  };
}

/** A sign-in attempt finished. */
export function reportMcpAuthResult(input: { outcome: McpAuthOutcome; registration: 'cimd' | 'dcr' | 'none'; trigger: McpAuthTrigger }): void {
  trackEvent('mcp_auth_result', mcpAuthResultEvent(input));
}

// ── mcp_tools_changed / mcp_server_removed ──────────────────────────────

/**
 * The name used for `tool_call_unhandled.toolName`. The MCP tool name sent to the model is
 * `mcp_<server short name>_<tool name>`: the short name comes from the server name the user chose
 * and the rest is a third party's tool name, and neither may enter telemetry. Anything starting
 * with `mcp_` is replaced with this fixed value, because a name the model made up that is not in
 * the lookup table can carry the same information. Other (built-in) tool names are recorded as is.
 */
export const MCP_TELEMETRY_TOOL_NAME = 'mcp_tool';

export function telemetryToolName(name: string): string {
  return name.toLowerCase().startsWith('mcp_') ? MCP_TELEMETRY_TOOL_NAME : name;
}

export function mcpToolsChangedEvent(changes: readonly Pick<McpToolChange, 'kind'>[]) {
  return {
    added: changes.filter((change) => change.kind === 'added').length,
    changed: changes.filter((change) => change.kind === 'changed').length,
    removed: changes.filter((change) => change.kind === 'removed').length,
  };
}

/** Tool changes were detected (nothing is reported when there are none). */
export function reportMcpToolsChanged(changes: readonly Pick<McpToolChange, 'kind'>[]): void {
  if (changes.length === 0) return;
  trackEvent('mcp_tools_changed', mcpToolsChangedEvent(changes));
}

export function reportMcpServerRemoved(): void {
  trackEvent('mcp_server_removed', {});
}
