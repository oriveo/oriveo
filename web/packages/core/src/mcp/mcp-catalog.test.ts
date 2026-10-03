import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  buildToolSnapshots,
  confirmToolSnapshots,
  defaultToolPermissions,
  diffToolSnapshots,
  isToolOversized,
  outboundToolSnapshots,
  permissionAfterConfirming,
} from './mcp-catalog';
import { MCP_RUNTIME_CONFIG_FALLBACK, parseToolDefinition, type McpToolDefinition } from './mcp-types';

const FIXTURES = resolve(__dirname, '../../../../../shared/test-fixtures/mcp');
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const load = (name: string): any => JSON.parse(readFileSync(resolve(FIXTURES, name), 'utf8'));
const SERVER = 'srv-1';
const config = MCP_RUNTIME_CONFIG_FALLBACK;

function tool(overrides: Partial<McpToolDefinition> & { name: string }): McpToolDefinition {
  return { title: null, description: 'd', inputSchema: { type: 'object', properties: {} }, annotations: {}, ...overrides };
}

describe('snapshots and default permissions', () => {
  it('freshly fetched tools are all pendingReview; read-only ones default to auto, the rest (including undeclared) to ask', () => {
    const snapshots = buildToolSnapshots({
      serverId: SERVER,
      definitions: [
        tool({ name: 'read', annotations: { readOnlyHint: true } }),
        tool({ name: 'write', annotations: { readOnlyHint: false } }),
        tool({ name: 'silent' }),
        tool({ name: 'read', description: 'duplicate ignored' }),
      ],
      runtimeConfig: config,
      now: 5,
    });
    expect(snapshots.map((s) => s.toolName)).toEqual(['read', 'write', 'silent']);
    expect(snapshots.every((s) => s.pendingReview)).toBe(true);
    expect(defaultToolPermissions(snapshots)).toEqual({ read: 'auto', write: 'ask', silent: 'ask' });
  });

  it('title precedence is title -> annotations.title -> name; inputSchema keeps its original property order', () => {
    const definition = parseToolDefinition({ name: 'n', annotations: { title: 'From annotations' }, inputSchema: { properties: { z: {}, a: {} } } })!;
    const [snapshot] = buildToolSnapshots({ serverId: SERVER, definitions: [definition], runtimeConfig: config });
    expect(snapshot!.title).toBe('From annotations');
    expect(Object.keys((snapshot!.inputSchema as { properties: object }).properties)).toEqual(['z', 'a']);
  });

  it('unchanged tools keep their existing quarantine flag; changed ones go back to quarantine', () => {
    const first = buildToolSnapshots({ serverId: SERVER, definitions: [tool({ name: 'a' }), tool({ name: 'b' })], runtimeConfig: config });
    const confirmed = first.map((s) => ({ ...s, pendingReview: false }));
    const second = buildToolSnapshots({
      serverId: SERVER,
      definitions: [tool({ name: 'a' }), tool({ name: 'b', description: 'changed' })],
      runtimeConfig: config,
      existing: confirmed,
    });
    expect(second.map((s) => [s.toolName, s.pendingReview])).toEqual([['a', false], ['b', true]]);
  });
});

describe('change detection', () => {
  it('every vector in tool-hash.json: a different hash means changed, the same hash means unchanged', () => {
    for (const testCase of load('tool-hash.json').cases) {
      const [before] = buildToolSnapshots({ serverId: SERVER, definitions: [parseToolDefinition(testCase.before)!], runtimeConfig: config });
      const after = buildToolSnapshots({
        serverId: SERVER,
        definitions: [parseToolDefinition(testCase.after)!],
        runtimeConfig: config,
        existing: [{ ...before!, pendingReview: false }],
      });
      expect(after[0]!.pendingReview).toBe(!testCase.expectEqual);
      expect(diffToolSnapshots([before!], after).length).toBe(testCase.expectEqual ? 0 : 1);
    }
  });

  it('changing only the display title also counts as a change and goes back to quarantine', () => {
    const [before] = buildToolSnapshots({ serverId: SERVER, definitions: [tool({ name: 'search', title: 'Search' })], runtimeConfig: config });
    const after = buildToolSnapshots({
      serverId: SERVER,
      definitions: [tool({ name: 'search', title: 'Delete everything' })],
      runtimeConfig: config,
      existing: [{ ...before!, pendingReview: false }],
    });
    expect(after[0]!.contentHash).toBe(before!.contentHash);
    expect(after[0]!.pendingReview).toBe(true);
    expect(diffToolSnapshots([before!], after)).toEqual([{ kind: 'changed', toolName: 'search', title: 'Delete everything' }]);
  });

  it('the three kinds: added / changed / removed', () => {
    const before = buildToolSnapshots({ serverId: SERVER, definitions: [tool({ name: 'keep' }), tool({ name: 'gone' }), tool({ name: 'edit' })], runtimeConfig: config });
    const after = buildToolSnapshots({
      serverId: SERVER,
      definitions: [tool({ name: 'keep' }), tool({ name: 'edit', description: 'x' }), tool({ name: 'new' })],
      runtimeConfig: config,
      existing: before,
    });
    expect(diffToolSnapshots(before, after).map((c) => `${c.kind}:${c.toolName}`)).toEqual(['added:new', 'changed:edit', 'removed:gone']);
  });
});

describe('outbound filtering', () => {
  it('quarantined, disabled and oversized tools are never sent out', () => {
    const big = 'x'.repeat(config.maxToolDefinitionBytes + 1);
    const snapshots = buildToolSnapshots({
      serverId: SERVER,
      definitions: [tool({ name: 'ok' }), tool({ name: 'off' }), tool({ name: 'big', description: big }), tool({ name: 'pending' })],
      runtimeConfig: config,
    }).map((s) => (s.toolName === 'pending' ? s : { ...s, pendingReview: false }));
    expect(isToolOversized(tool({ name: 'big', description: big }), config)).toBe(true);
    const outbound = outboundToolSnapshots(snapshots, { ok: 'ask', off: 'off', big: 'auto', pending: 'auto' });
    expect(outbound.map((s) => s.toolName)).toEqual(['ok']);
  });
});

describe('confirming changes (permissions only ever tighten)', () => {
  it('server changes again during confirmation -> stays quarantined; a tool that lost its read-only declaration drops from auto to ask after confirmation', () => {
    const original = [tool({ name: 'r', annotations: { readOnlyHint: true } }), tool({ name: 'moving' })];
    const shown = buildToolSnapshots({
      serverId: SERVER,
      definitions: [tool({ name: 'r', annotations: { readOnlyHint: false } }), tool({ name: 'moving' }), tool({ name: 'fresh' })],
      runtimeConfig: config,
      existing: buildToolSnapshots({ serverId: SERVER, definitions: original, runtimeConfig: config }).map((s) => ({ ...s, pendingReview: false })),
    });
    const result = confirmToolSnapshots({
      snapshots: shown.map((s) => (s.toolName === 'moving' ? { ...s, pendingReview: true } : s)),
      definitions: [tool({ name: 'r', annotations: { readOnlyHint: false } }), tool({ name: 'moving', description: 'changed again' }), tool({ name: 'fresh' })],
      permissions: { r: 'auto', moving: 'auto' },
      runtimeConfig: config,
    });
    expect(result.stillPending).toEqual(['moving']);
    expect(result.permissions).toEqual({ r: 'ask', moving: 'auto', fresh: 'ask' });
    expect(result.snapshots.find((s) => s.toolName === 'r')!.pendingReview).toBe(false);
    expect(result.snapshots.find((s) => s.toolName === 'moving')!.pendingReview).toBe(true);
  });

  it('confirmation never relaxes a permission', () => {
    expect(permissionAfterConfirming({ readOnly: true }, 'ask')).toBe('ask');
    expect(permissionAfterConfirming({ readOnly: true }, 'off')).toBe('off');
    expect(permissionAfterConfirming({ readOnly: false }, 'auto')).toBe('ask');
    expect(permissionAfterConfirming({ readOnly: true }, undefined)).toBe('auto');
  });
});
