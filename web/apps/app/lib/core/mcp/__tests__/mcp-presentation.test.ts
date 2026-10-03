import { describe, expect, it } from 'vitest';
import type { McpToolStep } from '@oriveo/shared';
import { MCP_RUNTIME_CONFIG_FALLBACK, planMcpTools, type McpConnectionState, type McpServerRecord, type McpToolSnapshot } from '@oriveo/core/mcp/index';
import {
  buildMcpPanelModel,
  estimateMcpToolTokens,
  mcpConfirmationFullText,
  mcpConfirmationHiddenCount,
  mcpConfirmationRows,
  mcpDisplayAddress,
  mcpDurationParts,
  mcpServerInitial,
} from '../mcp-presentation';
import { buildMcpStepsPresentation, mcpStepFailureKey } from '../mcp-steps-presentation';

const A = '11111111-1111-4111-8111-111111111111';
const B = '22222222-2222-4222-8222-222222222222';

function record(id: string, name: string): McpServerRecord {
  return { id, name, slug: name.toLowerCase(), url: `https://${name.toLowerCase()}.example.com/mcp`, authKind: 'auto', iconURL: null, createdAt: 1, updatedAt: 1, schemaVersion: 1 };
}

function snapshot(serverId: string, toolName: string, overrides: Partial<McpToolSnapshot> = {}): McpToolSnapshot {
  return {
    serverId, toolName, title: toolName, description: `Description of ${toolName}`, inputSchema: { type: 'object', properties: { q: { type: 'string' } } },
    annotations: {}, contentHash: `h-${toolName}`, readOnly: true, pendingReview: false, oversized: false, updatedAt: 1, ...overrides,
  };
}

const connected = (serverId: string, status: McpConnectionState['status'] = 'connected'): McpConnectionState =>
  ({ serverId, status, lastSuccessAt: 5, negotiatedVersion: null, generation: null, sessionId: null });

describe('tools panel numbers', () => {
  const base = {
    servers: [record(A, 'Alpha'), record(B, 'Beta')],
    snapshots: {
      [A]: [snapshot(A, 'a1'), snapshot(A, 'a2', { pendingReview: true }), snapshot(A, 'a3')],
      [B]: [snapshot(B, 'b1'), snapshot(B, 'b2')],
    },
    permissions: { [A]: { a3: 'off' as const } },
    connections: { [A]: connected(A), [B]: connected(B) },
    runtimeConfig: { ...MCP_RUNTIME_CONFIG_FALLBACK },
  };

  it('excludes quarantined and turned-off tools from each row count and counts only switched-on, usable servers on the pill', () => {
    const model = buildMcpPanelModel({ ...base, enabledServerIds: [A] });
    expect(model.rows.map((row) => [row.server.name, row.toolCount, row.enabled, row.hasPendingReview, row.status])).toEqual([
      ['Alpha', 1, true, true, 'ready'],
      ['Beta', 2, false, false, 'ready'],
    ]);
    expect(model.enabledCount).toBe(1);
    expect(model.toolCount).toBe(1);
  });

  it('leaves a server that needs reauthorization out of the number and the estimate even when switched on', () => {
    const model = buildMcpPanelModel({ ...base, connections: { [A]: connected(A, 'needsAuth'), [B]: connected(B) }, enabledServerIds: [A, B] });
    expect(model.rows[0].status).toBe('needsAuth');
    expect(model.enabledCount).toBe(1);
    expect(model.toolCount).toBe(2);
  });

  it('takes the estimate and truncation from the same assembly function as the send path: characters / 4, rounded to the nearest hundred', () => {
    const model = buildMcpPanelModel({ ...base, enabledServerIds: [A, B] });
    const plan = planMcpTools(
      [A, B].map((id) => ({ record: base.servers.find((server) => server.id === id)!, connectionStatus: 'connected' as const, snapshots: base.snapshots[id], permissions: (base.permissions as Record<string, Record<string, 'off'>>)[id] ?? {} })),
      base.runtimeConfig,
    );
    expect(model.toolCount).toBe(plan.tools.length);
    const characters = plan.tools.reduce((total, tool) => total + JSON.stringify(tool.definition).length, 0);
    expect(model.estimatedTokens).toBe(Math.max(100, Math.round(characters / 4 / 100) * 100));
    expect(model.estimatedTokens % 100).toBe(0);
    expect(estimateMcpToolTokens({ tools: [] })).toBe(0);

    const truncated = buildMcpPanelModel({ ...base, enabledServerIds: [A, B], runtimeConfig: { ...MCP_RUNTIME_CONFIG_FALLBACK, maxToolsPerRequest: 2 } });
    expect(truncated).toMatchObject({ truncated: true, toolCount: 2 });
  });

  it('has no tools to send when the master switch is off', () => {
    const model = buildMcpPanelModel({ ...base, enabledServerIds: [A, B], runtimeConfig: { ...MCP_RUNTIME_CONFIG_FALLBACK, enabled: false } });
    expect(model).toMatchObject({ toolCount: 0, estimatedTokens: 0 });
  });
});

describe('argument rows of the confirmation dialog', () => {
  const schema = { type: 'object', properties: { parent: {}, title: {}, content: {}, tags: {}, draft: {} } };

  it('lists the first 4 top-level arguments in the order of the server schema, with undeclared ones after them and keys verbatim', () => {
    const rows = mcpConfirmationRows({ extra: 1, draft: true, title: 'T', parent: 'P' }, schema);
    expect(rows.map((row) => [row.key, row.value])).toEqual([['parent', 'P'], ['title', 'T'], ['draft', 'true'], ['extra', '1']]);
    expect(mcpConfirmationHiddenCount({ a: 1, b: 2, c: 3, d: 4, e: 5 })).toBe(1);
    expect(mcpConfirmationHiddenCount({ a: 1 })).toBe(0);
  });

  it('gives only the length of a long text, with the full text listed verbatim on the second layer', () => {
    const long = 'あ'.repeat(640);
    const [row] = mcpConfirmationRows({ content: long }, schema);
    expect(row).toMatchObject({ key: 'content', value: null, length: 640, full: long });
    expect(mcpConfirmationFullText({ content: long, tags: ['a', 'b'] })).toEqual([
      { key: 'content', text: long },
      { key: 'tags', text: '[\n  "a",\n  "b"\n]' },
    ]);
  });

  it('uses the order given by the model when the schema is not an object', () => {
    expect(mcpConfirmationRows({ b: '2', a: '1' }, null).map((row) => row.key)).toEqual(['b', 'a']);
  });
});

describe('step block presentation rules (same as McpToolStepsPresentation on iOS)', () => {
  const step = (overrides: Partial<McpToolStep>): McpToolStep => ({
    id: '1:a', scope: 'mcp', serverId: A, serverName: 'Alpha', toolName: 't', title: 'T', argsSummary: 'x', status: 'done', step: 1, ...overrides,
  });

  it('counts successful steps in the title when complete, and on the right prefers failed, then denied, then the server names', () => {
    const steps = [step({ id: '1' }), step({ id: '2', step: 2, serverName: 'Beta' }), step({ id: '3', step: 3, status: 'denied' })];
    expect(buildMcpStepsPresentation({ steps, isGenerating: false })).toMatchObject({ header: { finished: 2 }, trailing: { kind: 'declined', count: 1 }, isActive: false });
    expect(buildMcpStepsPresentation({ steps: [...steps, step({ id: '4', step: 4, status: 'failed' })], isGenerating: false }).trailing).toEqual({ kind: 'failed', count: 1 });
    expect(buildMcpStepsPresentation({ steps: steps.slice(0, 2), isGenerating: false }).trailing).toEqual({ kind: 'servers', names: ['Alpha', 'Beta'] });
  });

  it('keeps only the last 2 steps beyond 5 and shows the limit note only after the reply ends', () => {
    const steps = Array.from({ length: 6 }, (_, index) => step({ id: String(index), step: index + 1 }));
    expect(buildMcpStepsPresentation({ steps, isGenerating: false, limitReached: true })).toMatchObject({ hiddenEarlierCount: 4, limitReached: true });
    expect(buildMcpStepsPresentation({ steps: steps.slice(0, 5), isGenerating: false }).hiddenEarlierCount).toBe(0);
    expect(buildMcpStepsPresentation({ steps, isGenerating: true, limitReached: true }).limitReached).toBe(false);
  });

  it('treats waiting for authorization as valid only while generating, and picks the failure text by closed-set error code', () => {
    const steps = [step({ id: 'p', status: 'needsAuth', errorCode: 'needs_auth', step: 3 })];
    expect(buildMcpStepsPresentation({ steps, isGenerating: true, pausedStepId: 'p' })).toMatchObject({ header: 'waitingAuth', trailing: { kind: 'step', step: 3 } });
    expect(buildMcpStepsPresentation({ steps, isGenerating: false, pausedStepId: 'p' }).pausedStep).toBeNull();
    expect(['timeout', 'unreachable', 'result_too_large', 'tool_unavailable', 'auth_skipped', 'server_error', undefined].map(mcpStepFailureKey)).toEqual([
      'stepTimeout', 'stepUnreachable', 'stepTooLarge', 'stepUnavailable', 'stepSkipped', 'stepFailed', 'stepFailed',
    ]);
  });
});

describe('helpers', () => {
  it('formats duration, display address and initial letter', () => {
    expect(mcpDurationParts(340)).toEqual({ unit: 'ms', value: 340 });
    expect(mcpDurationParts(1234)).toEqual({ unit: 's', value: 1.2 });
    // The query string may carry a secret: not shown
    expect(mcpDisplayAddress('https://mcp.linear.app/mcp?key=SECRET')).toBe('mcp.linear.app/mcp');
    expect(mcpDisplayAddress('https://example.com/')).toBe('example.com');
    expect(mcpServerInitial('  linear')).toBe('L');
    expect(mcpServerInitial('')).toBe('?');
  });
});
