import 'fake-indexeddb/auto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { McpServerAddition, McpToolSnapshot } from '@oriveo/core/mcp/index';

/**
 * Cross-tab invalidation: two tabs of the same browser share IndexedDB but each has its own in-memory
 * projection and credential cache. After one tab writes to the database, the other has to drop its
 * cache and re-read from the database. The two "tabs" are two fresh module instances, and every write
 * goes through the production entry points of `mcp-store`.
 */

const SERVER_ID = '00000000-0000-4000-8000-0000000000aa';

/** Stand-in for a same-origin BroadcastChannel: instances of the same channel name receive each other's messages, never their own, and delivery is asynchronous. */
function installBroadcastChannel() {
  const instances = new Set<FakeChannel>();
  class FakeChannel {
    private readonly listeners = new Set<(event: MessageEvent) => void>();
    constructor(readonly name: string) {
      instances.add(this);
    }
    postMessage(data: unknown): void {
      for (const other of instances) {
        if (other === this || other.name !== this.name) continue;
        queueMicrotask(() => {
          for (const listener of other.listeners) listener(new MessageEvent('message', { data: structuredClone(data) }));
        });
      }
    }
    addEventListener(_type: string, listener: (event: MessageEvent) => void): void {
      this.listeners.add(listener);
    }
    removeEventListener(_type: string, listener: (event: MessageEvent) => void): void {
      this.listeners.delete(listener);
    }
    close(): void {
      instances.delete(this);
    }
  }
  vi.stubGlobal('BroadcastChannel', FakeChannel);
}

function snapshot(toolName: string): McpToolSnapshot {
  return {
    serverId: SERVER_ID,
    toolName,
    title: toolName,
    description: null,
    inputSchema: { type: 'object' },
    annotations: {},
    contentHash: `hash-${toolName}`,
    readOnly: false,
    pendingReview: false,
    oversized: false,
    updatedAt: 1,
  };
}

const addition: McpServerAddition = {
  id: SERVER_ID,
  name: 'Example',
  url: 'https://mcp.example.com/mcp',
  authKind: 'auto',
  iconURL: null,
  createdAt: 1,
  snapshots: [snapshot('create_issue'), snapshot('close_issue')],
  permissions: { create_issue: 'auto', close_issue: 'ask' },
  connectionState: { serverId: SERVER_ID, status: 'connected', lastSuccessAt: 1, negotiatedVersion: '2026-07-28', generation: 'stateless', sessionId: null },
};

async function openTab(uid: string) {
  vi.resetModules();
  const store = await import('../mcp-store');
  const confirmation = await import('../mcp-confirmation');
  const idb = await import('../mcp-idb');
  await store.useMcpStore.getState().hydrate(uid);
  return { store, idb, state: () => store.useMcpStore.getState(), grants: confirmation.mcpConversationGrants };
}

let counter = 0;
let uid = '';

beforeEach(() => {
  uid = `uid-cross-tab-${++counter}`;
  installBroadcastChannel();
});
afterEach(() => vi.unstubAllGlobals());

async function twoTabs() {
  const first = await openTab(uid);
  await first.idb.createIdbMcpServerRepository(uid).addServer(addition, 20);
  await first.state().reload();
  const second = await openTab(uid);
  expect(second.state().servers.map((server) => server.id)).toEqual([SERVER_ID]);
  return { first, second };
}

describe('MCP store cross-tab invalidation', () => {
  it('propagates a tool switched to ask-every-time in one tab to the other tab and revokes an allow-for-this-conversation grant given there', async () => {
    const { first, second } = await twoTabs();
    second.grants.grant('conv-1', SERVER_ID, 'create_issue');
    second.grants.grant('conv-1', SERVER_ID, 'close_issue');

    await first.state().setToolPermission(SERVER_ID, 'create_issue', 'ask');

    await vi.waitFor(() => expect(second.state().permissions[SERVER_ID]).toEqual({ create_issue: 'ask', close_issue: 'ask' }));
    await vi.waitFor(() => expect(second.grants.isGranted('conv-1', SERVER_ID, 'create_issue')).toBe(false));
    // The tool that was not touched is unaffected
    expect(second.grants.isGranted('conv-1', SERVER_ID, 'close_issue')).toBe(true);
  });

  it('removes a server deleted in one tab from the list, snapshots and conversation switches of the other tab', async () => {
    const { first, second } = await twoTabs();
    await second.state().setServerEnabled('conv-1', SERVER_ID, true);
    await vi.waitFor(() => expect(first.state().conversationServers).toEqual({ 'conv-1': [SERVER_ID] }));
    second.grants.grant('conv-1', SERVER_ID, 'create_issue');

    await first.state().removeServer(SERVER_ID);

    await vi.waitFor(() => expect(second.state().servers).toEqual([]));
    expect(second.state().snapshots).toEqual({});
    expect(second.state().conversationServers['conv-1'] ?? []).toEqual([]);
    await vi.waitFor(() => expect(second.grants.isGranted('conv-1', SERVER_ID, 'create_issue')).toBe(false));
  });

  it('stops the other tab from using its cached old token after one tab replaces the credentials', async () => {
    const { first, second } = await twoTabs();
    await first.store.getMcpAuthorizer(uid).storePastedToken('token-v1', SERVER_ID, uid);
    await vi.waitFor(async () => expect(await second.store.getMcpAuthorizer(uid).validAccessToken(SERVER_ID, uid)).toBe('token-v1'));

    await first.store.getMcpAuthorizer(uid).storePastedToken('token-v2', SERVER_ID, uid);

    await vi.waitFor(async () => expect(await second.store.getMcpAuthorizer(uid).validAccessToken(SERVER_ID, uid)).toBe('token-v2'));
  });

  it('ignores notifications from another partition', async () => {
    const { second } = await twoTabs();
    const reload = vi.spyOn(second.state(), 'reload');
    const other = await openTab(`${uid}-other`);
    await other.idb.createIdbMcpServerRepository(`${uid}-other`).addServer({ ...addition, id: '00000000-0000-4000-8000-0000000000bb' }, 20);
    await other.state().reload();
    await other.state().setToolPermission('00000000-0000-4000-8000-0000000000bb', 'create_issue', 'off');
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(reload).not.toHaveBeenCalled();
    expect(second.state().servers.map((server) => server.id)).toEqual([SERVER_ID]);
  });
});
