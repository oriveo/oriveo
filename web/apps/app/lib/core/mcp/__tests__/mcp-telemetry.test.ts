// Outbound shape of the MCP telemetry events. The event objects are built by the production report*
// functions, and only what survives the real telemetry sanitizer (sanitizeProperties) is what
// actually leaves the app, so these tests assert on what is left after sanitizing.
//
// Assertions that each event fires in the real flows live elsewhere: mcp_tool_call in
// operations-mcp-send.test.ts (the production send path), mcp_confirm_choice in
// McpConfirmationDialog.test.tsx, mcp_server_add_result / mcp_auth_result in
// McpAddServerDialog.test.tsx and McpServerDialogs.test.tsx (against a real mock server), and
// mcp_tools_changed / mcp_server_removed in McpServersPage.test.tsx.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import { TELEMETRY_EVENTS, sanitizeProperties } from '@oriveo/shared';
import type { McpAddState, McpToolStepUpdate } from '@oriveo/core/mcp/index';

const mocks = vi.hoisted(() => ({ trackEvent: vi.fn() }));
vi.mock('../../telemetry', () => ({ trackEvent: mocks.trackEvent }));

import {
  mcpDurationBucket,
  reportMcpAuthResult,
  reportMcpConfirmChoice,
  reportMcpServerAddResult,
  reportMcpServerRemoved,
  reportMcpToolCall,
  reportMcpToolsChanged,
} from '../mcp-telemetry';

/** The most recent outbound event: its name plus the sanitized properties. */
function sent(): { name: string; props: Record<string, unknown> } {
  const [name, props] = mocks.trackEvent.mock.calls.at(-1)!;
  return { name, props: sanitizeProperties(props) as Record<string, unknown> };
}

function update(overrides: Partial<McpToolStepUpdate> = {}): McpToolStepUpdate {
  return {
    id: '1:call_1',
    serverId: 'SERVER-ID',
    serverName: 'PRIVATE-SERVER-NAME',
    toolName: 'private_tool_name',
    title: 'Private tool title',
    argsSummary: 'private args',
    status: 'done',
    errorCode: null,
    step: 1,
    durationMs: 1234,
    permission: 'ask',
    readOnly: false,
    awaitingUser: false,
    payload: { arguments: '{"secret":"PRIVATE-ARGS"}', resultPrefix: 'PRIVATE-RESULT' },
    ...overrides,
  };
}

beforeEach(() => mocks.trackEvent.mockReset());

describe('event registration (a registered event must have a producer)', () => {
  it('lists all six events in the event table shared by all clients', () => {
    for (const name of ['mcp_server_add_result', 'mcp_auth_result', 'mcp_tool_call', 'mcp_confirm_choice', 'mcp_tools_changed', 'mcp_server_removed']) {
      expect(TELEMETRY_EVENTS).toContain(name);
    }
  });
});

describe('mcp_tool_call', () => {
  it('keeps exactly five fields after sanitizing (errorCode survives the "contains code" substring rule)', () => {
    reportMcpToolCall(update({ status: 'failed', errorCode: 'timeout' }));
    expect(sent()).toEqual({
      name: 'mcp_tool_call',
      props: { status: 'failed', errorCode: 'timeout', permission: 'ask', durationBucket: '1_5s', readOnly: false },
    });
  });

  it('carries no server name, tool name, arguments or result', () => {
    reportMcpToolCall(update());
    const serialized = JSON.stringify(mocks.trackEvent.mock.calls);
    for (const secret of ['SERVER-ID', 'PRIVATE-SERVER-NAME', 'private_tool_name', 'Private tool title', 'private args', 'PRIVATE-ARGS', 'PRIVATE-RESULT']) {
      expect(serialized).not.toContain(secret);
    }
    expect(sent().props).toMatchObject({ status: 'done', errorCode: 'none' });
  });

  it('reports duration only as a bucket', () => {
    expect([null, undefined, 0, 999, 1000, 4999, 5000, 14_999, 15_000, 59_999, 60_000, Number.NaN].map((value) => mcpDurationBucket(value))).toEqual([
      'none', 'none', 'lt_1s', 'lt_1s', '1_5s', '1_5s', '5_15s', '5_15s', '15_60s', '15_60s', 'gte_60s', 'none',
    ]);
  });
});

describe('mcp_confirm_choice', () => {
  it.each(['once', 'conversation', 'deny'] as const)('%s', (choice) => {
    reportMcpConfirmChoice(choice);
    expect(sent()).toEqual({ name: 'mcp_confirm_choice', props: { choice } });
  });
});

describe('mcp_server_add_result', () => {
  const review: McpAddState = {
    kind: 'review',
    review: {
      serverId: 'SERVER-ID',
      session: { generation: 'session', protocolVersion: '2025-11-25', sessionId: 'SESSION-SECRET', serverName: 'PRIVATE-SERVER-NAME' },
      tools: [],
      defaultPermissions: {},
    },
  };

  it('success: outcome / authKind / protocolGeneration survive sanitizing (authKind survives the "contains auth" rule), with no session id or server name', () => {
    reportMcpServerAddResult(review, 'token');
    expect(sent()).toEqual({ name: 'mcp_server_add_result', props: { outcome: 'added', authKind: 'token', protocolGeneration: 'session' } });
    expect(JSON.stringify(mocks.trackEvent.mock.calls)).not.toMatch(/SESSION-SECRET|PRIVATE-SERVER-NAME|SERVER-ID/);
  });

  it('maps every terminal state to one outcome from the closed set', () => {
    const terminal: McpAddState[] = [
      { kind: 'invalidURL', reason: 'malformed' }, { kind: 'unreachable' }, { kind: 'notMcp' }, { kind: 'needsToken' },
      { kind: 'tokenRejected' }, { kind: 'authCancelled' }, { kind: 'limitReached', max: 20 }, { kind: 'cancelled' }, { kind: 'saveFailed' },
    ];
    for (const state of terminal) reportMcpServerAddResult(state, 'auto');
    expect(mocks.trackEvent.mock.calls.map(([, props]) => props.outcome)).toEqual([
      'invalid_url', 'unreachable', 'not_mcp', 'needs_token', 'token_rejected', 'auth_cancelled', 'limit_reached', 'cancelled', 'save_failed',
    ]);
    expect(mocks.trackEvent.mock.calls.every(([, props]) => props.protocolGeneration === 'none')).toBe(true);
  });

  it('does not report in-progress states, which are not results', () => {
    const progress: McpAddState[] = [{ kind: 'connecting' }, { kind: 'authPrompt', authorizationHost: 'auth.example.com' }, { kind: 'browser' }, { kind: 'finishing' }];
    for (const state of progress) reportMcpServerAddResult(state, 'auto');
    expect(mocks.trackEvent).not.toHaveBeenCalled();
  });
});

describe('mcp_auth_result', () => {
  it('outcome / registration / trigger', () => {
    reportMcpAuthResult({ outcome: 'connected', registration: 'dcr', trigger: 'mid_loop' });
    expect(sent()).toEqual({ name: 'mcp_auth_result', props: { outcome: 'success', registration: 'dcr', trigger: 'mid_loop' } });
    reportMcpAuthResult({ outcome: 'cancelled', registration: 'cimd', trigger: 'reauth' });
    expect(sent().props).toEqual({ outcome: 'cancelled', registration: 'cimd', trigger: 'reauth' });
    reportMcpAuthResult({ outcome: 'unreachable', registration: 'none', trigger: 'add' });
    expect(sent().props).toEqual({ outcome: 'unreachable', registration: 'none', trigger: 'add' });
  });
});

describe('mcp_tools_changed and mcp_server_removed', () => {
  it('carries only three counts and no tool names', () => {
    reportMcpToolsChanged([{ kind: 'added' }, { kind: 'added' }, { kind: 'changed' }, { kind: 'removed' }]);
    expect(sent()).toEqual({ name: 'mcp_tools_changed', props: { added: 2, changed: 1, removed: 1 } });
  });

  it('reports nothing when there are no changes', () => {
    reportMcpToolsChanged([]);
    expect(mocks.trackEvent).not.toHaveBeenCalled();
  });

  it('server removal carries no fields at all', () => {
    reportMcpServerRemoved();
    expect(sent()).toEqual({ name: 'mcp_server_removed', props: {} });
  });
});
