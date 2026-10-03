/**
 * The page origin is set to public https: the web CIMD `client_id` and callback address are derived
 * from the current origin, and jsdom's default `http://localhost` origin does not use CIMD.
 * @vitest-environment-options { "url": "https://app.example.com/" }
 */
// The MCP server management page in settings, against the real MCP store (fake-indexeddb).
// Flows that need a real connection (re-reading tools, removal) store a server through the production
// add flow and then run against the mock server; layout-only cases put the store's in-memory state
// directly into the desired shape.

import 'fake-indexeddb/auto';
import { act, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MCP_RUNTIME_CONFIG_FALLBACK, type McpRuntimeConfig } from '@oriveo/core/mcp/index';

const mocks = vi.hoisted(() => ({
  push: vi.fn(),
  replace: vi.fn(),
  search: '',
  trackEvent: vi.fn(),
  runtimeConfig: null as McpRuntimeConfig | null,
}));
vi.mock('next-intl', async () => await import('use-intl'));
vi.mock('next/navigation', () => ({
  useRouter: () => ({ push: mocks.push, replace: mocks.replace }),
  useSearchParams: () => new URLSearchParams(mocks.search),
}));
vi.mock('../../../lib/core/telemetry', () => ({ trackEvent: mocks.trackEvent }));
vi.mock('../../../lib/core/metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/metadata/metadata-client')>()),
  getMcpRuntimeConfig: () => mocks.runtimeConfig,
}));

import { GITHUB, LINEAR, NOTION, connection, renderWithIntl, seedMcpStore, server, tool } from '../../../components/mcp/__tests__/mcp-test-kit';
import { fakeAuthorizationWindow, killAllMockServers, startMockServer, type MockServer } from '../../../components/mcp/__tests__/mock-server-kit';
import { loadMcpLocalState } from '../../../lib/core/mcp/mcp-idb';
import { acceptMcpAddedTools, pendingMcpToolChanges } from '../../../lib/core/mcp/mcp-server-actions';
import { __setMcpTransportForTests, getMcpCredentialStore, useMcpStore } from '../../../lib/core/mcp/mcp-store';
import { McpServersPage } from './McpServersPage';

let uidCounter = 0;
let uid = '';
let mock: MockServer | null = null;

async function addRealServer(...flags: string[]): Promise<string> {
  mock = await startMockServer(...flags);
  __setMcpTransportForTests(mock.transport);
  const state = await useMcpStore.getState().addServer({
    url: mock.endpoint,
    name: 'Mock',
    authKind: 'auto',
    confirmAuthorization: async () => true,
    launcher: fakeAuthorizationWindow(mock).launcher,
  });
  if (state.kind !== 'review') throw new Error(`add failed: ${state.kind}`);
  await acceptMcpAddedTools(state.review.serverId, state.review.defaultPermissions);
  return state.review.serverId;
}

function seedThree() {
  seedMcpStore({
    uid,
    servers: [server(LINEAR, 'Linear', { url: 'https://mcp.linear.app/mcp?team=acme' }), server(NOTION, 'Notion'), server(GITHUB, 'GitHub', { authKind: 'token' })],
    snapshots: {
      [LINEAR]: [
        tool(LINEAR, 'search_issues', { title: 'Search issues' }),
        tool(LINEAR, 'read_issue', { title: 'Read issue' }),
        tool(LINEAR, 'list_projects', { title: 'List projects' }),
        tool(LINEAR, 'list_teams', { title: 'List teams' }),
        tool(LINEAR, 'list_users', { title: 'List users' }),
        tool(LINEAR, 'create_issue', { title: 'Create issue', readOnly: false }),
        tool(LINEAR, 'update_issue', { title: 'Update issue', readOnly: false, description: null }),
      ],
      [NOTION]: Array.from({ length: 14 }, (_, index) => tool(NOTION, `notion_${index}`)),
      [GITHUB]: [tool(GITHUB, 'list_repos')],
    },
    permissions: { [LINEAR]: { update_issue: 'off' } },
    connections: { [LINEAR]: connection(LINEAR, 'connected'), [NOTION]: connection(NOTION, 'connected'), [GITHUB]: connection(GITHUB, 'needsAuth') },
  });
}

const events = (name: string) => mocks.trackEvent.mock.calls.filter(([event]) => event === name).map(([, props]) => props);
const cards = () => Array.from(document.querySelectorAll('[data-mcp-server]')) as HTMLElement[];
const detail = () => document.querySelector('[data-mcp-detail]') as HTMLElement;
const split = () => document.querySelector('[data-view]') as HTMLElement;

beforeEach(async () => {
  uidCounter += 1;
  uid = `uid-mcp-page-${uidCounter}`;
  mocks.push.mockReset();
  mocks.replace.mockReset();
  mocks.trackEvent.mockReset();
  mocks.search = '';
  mocks.runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK };
  useMcpStore.getState().reset();
  await useMcpStore.getState().hydrate(uid);
});

afterEach(() => {
  mock?.stop();
  mock = null;
  __setMcpTransportForTests(null);
});
afterAll(killAllMockServers);

describe('no servers yet', () => {
  it('title, description, three promises, primary button; pressing the primary button opens the add dialog', () => {
    renderWithIntl(<McpServersPage />);
    const empty = document.querySelector('[data-mcp-state="empty"]') as HTMLElement;
    expect(within(empty).getByRole('heading', { name: 'Let the model use your services' })).not.toBeNull();
    expect(within(empty).getAllByRole('listitem').map((item) => item.textContent)).toEqual([
      'Sign-in details stay in this browser',
      'Anything that changes your data asks you first',
      'Turn it on or off per chat',
    ]);
    expect(screen.queryByRole('dialog')).toBeNull();
    fireEvent.click(within(empty).getByRole('button', { name: 'Add server' }));
    expect(within(screen.getByRole('dialog')).getByRole('heading', { name: 'Add server' })).not.toBeNull();
  });

  it('arriving from the chat empty state (?add=1): the add dialog opens directly', () => {
    mocks.search = 'add=1';
    renderWithIntl(<McpServersPage />);
    expect(within(screen.getByRole('dialog')).getByRole('heading', { name: 'Add server' })).not.toBeNull();
  });
});

describe('list left, detail right', () => {
  it('list: one card per server with status pill and description; on wide screens the right side defaults to the first server', () => {
    seedThree();
    renderWithIntl(<McpServersPage />);
    expect(screen.getByRole('heading', { level: 1, name: 'MCP servers' })).not.toBeNull();
    expect(cards().map((card) => [card.textContent, card.getAttribute('data-status'), card.getAttribute('aria-current')])).toEqual([
      ['LLinearConnected6 tools', 'connected', 'true'],
      ['NNotionConnected14 tools', 'connected', null],
      ['GGitHubSign-in expiredNeeds sign-in again', 'needsAuth', null],
    ]);
    expect(screen.getByText('Tools come from third parties, and what they return is passed to the model. Only connect servers you trust.')).not.toBeNull();
    expect(detail().getAttribute('data-mcp-detail')).toBe(LINEAR);
  });

  it('detail: the address is shown without its query string; both tool groups show a count, 3 tools each by default, the rest collapsed', () => {
    seedThree();
    renderWithIntl(<McpServersPage />);
    const pane = detail();
    expect(Array.from(pane.querySelectorAll('dt')).map((node) => node.textContent)).toEqual(['Address', 'Sign-in', 'Last connected']);
    expect(pane.querySelector('dd')?.textContent).toBe('mcp.linear.app/mcp');
    const readOnly = pane.querySelector('[data-mcp-group="readOnly"]') as HTMLElement;
    const changes = pane.querySelector('[data-mcp-group="changes"]') as HTMLElement;
    expect(within(readOnly).getByRole('heading').textContent).toBe('Read only');
    expect(readOnly.textContent).toContain('5');
    expect(within(readOnly).getAllByRole('combobox')).toHaveLength(3);
    expect(within(changes).getAllByRole('combobox').map((select) => (select as HTMLSelectElement).value)).toEqual(['ask', 'off']);
    fireEvent.click(within(readOnly).getByRole('button', { name: 'Show 2 more' }));
    expect(within(readOnly).getAllByRole('combobox')).toHaveLength(5);
  });

  it('changing the permission of a single tool is written to the local store', async () => {
    const id = await addRealServer('--mode=stateless');
    renderWithIntl(<McpServersPage />);
    const select = within(detail()).getByRole('combobox', { name: 'Permission for Create Issue' }) as HTMLSelectElement;
    expect(select.value).toBe('ask');
    await act(async () => {
      fireEvent.change(select, { target: { value: 'off' } });
    });
    await waitFor(async () => expect((await loadMcpLocalState(uid)).permissions[id]).toEqual({ get_weather: 'auto', create_issue: 'off' }));
    // A tool set to "do not use" does not count towards the available tools.
    expect(cards()[0].textContent).toBe('MMockConnected1 tool');
  });

  it('server provides no tools: a one-line explanation', () => {
    seedMcpStore({ uid, servers: [server(LINEAR, 'Linear')] });
    renderWithIntl(<McpServersPage />);
    expect(within(detail()).getByText("This server doesn't offer any tools.")).not.toBeNull();
  });
});

describe('narrow single column', () => {
  it('the list when nothing is selected, the detail once something is, with a way back to the list at the top (layout switched by data-view)', () => {
    seedThree();
    renderWithIntl(<McpServersPage />);
    expect(split().getAttribute('data-view')).toBe('list');
    fireEvent.click(cards()[1]);
    expect(split().getAttribute('data-view')).toBe('detail');
    expect(detail().getAttribute('data-mcp-detail')).toBe(NOTION);
    fireEvent.click(within(detail()).getByRole('button', { name: 'All servers' }));
    expect(split().getAttribute('data-view')).toBe('list');
  });

  it('arriving with ?server=<id>: the detail of that server directly', () => {
    seedThree();
    mocks.search = `server=${NOTION}`;
    renderWithIntl(<McpServersPage />);
    expect(split().getAttribute('data-view')).toBe('detail');
    expect(detail().getAttribute('data-mcp-detail')).toBe(NOTION);
  });
});

describe('permission of a single tool', () => {
  it('the description given by the server plus a three-way radio; the default option is marked "recommended"; for a tool that modifies data the "run automatically" description is the warning', () => {
    seedThree();
    renderWithIntl(<McpServersPage />);
    fireEvent.click(within(detail()).getByRole('button', { name: 'Create issue' }));
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByRole('heading', { name: 'Create issue' })).not.toBeNull();
    expect(within(dialog).getByText('Description from the server (original)')).not.toBeNull();
    expect(within(dialog).getByText('Description of create_issue')).not.toBeNull();
    const radios = within(dialog).getAllByRole('radio');
    expect(radios.map((radio) => [radio.getAttribute('data-mcp-permission'), radio.getAttribute('aria-checked'), radio.textContent])).toEqual([
      ['auto', 'false', 'Run automaticallyThe model can change your data in Linear without asking.'],
      ['ask', 'true', 'Ask every timeRecommendedShows you what the model is about to send before each call.'],
      ['off', 'false', "Don't useThis tool isn't offered to the model."],
    ]);
    expect(radios[0].querySelector('[data-tone="warning"]')).not.toBeNull();
  });

  it('read-only tool: "run automatically" is the recommended one, without a warning; a tool without a description says so', () => {
    seedThree();
    renderWithIntl(<McpServersPage />);
    fireEvent.click(within(detail()).getByRole('button', { name: 'List projects' }));
    let radios = within(screen.getByRole('dialog')).getAllByRole('radio');
    expect(radios[0].textContent).toBe('Run automaticallyRecommendedThe model can use this tool without asking.');
    expect(radios[0].querySelector('[data-tone="warning"]')).toBeNull();
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Done' }));

    fireEvent.click(within(detail()).getByRole('button', { name: 'Update issue' }));
    expect(within(screen.getByRole('dialog')).getByText("The server didn't provide a description.")).not.toBeNull();
    radios = within(screen.getByRole('dialog')).getAllByRole('radio');
    expect(radios[2].getAttribute('aria-checked')).toBe('true');
  });
});

describe('authorization expired', () => {
  it('the hero card button becomes the primary "re-authorize" button; the tool list is dimmed and cannot be changed', () => {
    seedThree();
    renderWithIntl(<McpServersPage />);
    fireEvent.click(cards()[2]);
    const pane = detail();
    expect(pane.getAttribute('data-status')).toBe('needsAuth');
    expect(within(pane).getByText('Tools unavailable for now')).not.toBeNull();
    expect(pane.querySelector('[data-mcp-action="reauth"]')?.textContent).toBe('Sign in again');
    expect(pane.querySelector('[data-mcp-action="reload"]')).toBeNull();
    expect(pane.querySelector('[data-dimmed]')).not.toBeNull();
    for (const select of within(pane).getAllByRole('combobox')) expect((select as HTMLSelectElement).disabled).toBe(true);
    // For a server using an access token, the sign-in method truthfully says access token.
    expect(Array.from(pane.querySelectorAll('dd')).map((node) => node.textContent)[1]).toBe('Access token');
  });
});

describe('re-reading tools leads to the tool change confirmation', () => {
  it('server changed a tool description: one mcp_tools_changed is recorded (counts only), the change confirmation appears, list and detail show pending confirmation', async () => {
    const id = await addRealServer('--mode=stateless', '--mutable-tools');
    renderWithIntl(<McpServersPage />);
    await act(async () => {
      fireEvent.click(detail().querySelector('[data-mcp-action="reload"]')!);
    });
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeNull());
    expect(within(screen.getByRole('dialog')).getByRole('heading').textContent).toBe("Mock's tools have changed");
    expect(events('mcp_tools_changed')).toEqual([{ added: 0, changed: 1, removed: 0 }]);
    expect(JSON.stringify(mocks.trackEvent.mock.calls)).not.toMatch(/get_weather|Weather|127\.0\.0\.1|Mock/);
    expect(cards()[0].getAttribute('data-status')).toBe('needsReview');
    expect((await loadMcpLocalState(uid)).snapshots[id].find((item) => item.toolName === 'get_weather')?.pendingReview).toBe(true);

    // "Disable this server for now": turns off its switch in every conversation and keeps the quarantine.
    await useMcpStore.getState().setServerEnabled('conversation-1', id, true);
    await act(async () => {
      fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Pause this server for now' }));
    });
    await waitFor(() => expect(useMcpStore.getState().conversationServers['conversation-1']).toEqual([]));
    expect(screen.queryByRole('dialog')).toBeNull();
    // The detail keeps an entry so the user can come back and confirm at any time.
    expect(detail().querySelector('[data-mcp-action="review"]')?.textContent).toBe('Review changes');
  });

  it('no change: no confirmation and no analytics event', async () => {
    await addRealServer('--mode=stateless');
    renderWithIntl(<McpServersPage />);
    await act(async () => {
      fireEvent.click(detail().querySelector('[data-mcp-action="reload"]')!);
    });
    await waitFor(() => expect(detail().querySelector('[data-mcp-action="reload"]')?.textContent).toBe('Reload tools'));
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(events('mcp_tools_changed')).toEqual([]);
  });

  it('unreachable: says so, and the status pill becomes "cannot connect"', async () => {
    await addRealServer('--mode=stateless');
    mock!.stop();
    renderWithIntl(<McpServersPage />);
    await act(async () => {
      fireEvent.click(detail().querySelector('[data-mcp-action="reload"]')!);
    });
    await waitFor(() => expect(within(detail()).queryByRole('alert')).not.toBeNull());
    expect(within(detail()).getByRole('alert').textContent).toBe("Couldn't reach this server. Try again in a moment.");
    expect(cards()[0].getAttribute('data-status')).toBe('unreachable');
  });

  it('quarantined tools distinguish "added" from "description changed"; permissions after confirmation only go down, never up', () => {
    const snapshots = [
      tool(LINEAR, 'new_tool', { pendingReview: true, readOnly: false }),
      tool(LINEAR, 'was_readonly', { pendingReview: true, readOnly: false }),
      tool(LINEAR, 'still_readonly', { pendingReview: true }),
      tool(LINEAR, 'untouched'),
    ];
    expect(pendingMcpToolChanges(snapshots, { was_readonly: 'auto', still_readonly: 'auto', untouched: 'auto' }).map((change) => [change.snapshot.toolName, change.kind, change.permissionAfter])).toEqual([
      // No permission record = newly added: take the default.
      ['new_tool', 'added', 'ask'],
      // Was run-automatically and no longer declares read-only: falls back to ask-every-time.
      ['was_readonly', 'changed', 'ask'],
      ['still_readonly', 'changed', 'auto'],
    ]);
  });
});

describe('removing a server', () => {
  it('confirm first; after confirming, the local credential and record are deleted and one mcp_server_removed without any fields is recorded', async () => {
    const id = await addRealServer('--mode=oauth-cimd');
    expect(await getMcpCredentialStore(uid).load(id, uid)).not.toBeNull();
    renderWithIntl(<McpServersPage />);
    fireEvent.click(detail().querySelector('[data-mcp-action="remove"]')!);
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByRole('heading', { name: 'Remove Mock?' })).not.toBeNull();
    expect(within(dialog).getByText('This deletes the sign-in details saved in this browser and removes the server from the list. Tool records in existing chats are kept.')).not.toBeNull();
    // Not confirmed yet: nothing has been deleted.
    expect((await loadMcpLocalState(uid)).servers).toHaveLength(1);

    await act(async () => {
      fireEvent.click(within(dialog).getByRole('button', { name: 'Remove' }));
    });
    await waitFor(async () => expect((await loadMcpLocalState(uid)).servers).toEqual([]));
    expect(await getMcpCredentialStore(uid).load(id, uid)).toBeNull();
    expect(events('mcp_server_removed')).toEqual([{}]);
    // The last server is gone: back to the empty state.
    await waitFor(() => expect(document.querySelector('[data-mcp-state="empty"]')).not.toBeNull());
  });

  it('pressing cancel: nothing deleted, no analytics event', async () => {
    await addRealServer('--mode=stateless');
    renderWithIntl(<McpServersPage />);
    fireEvent.click(detail().querySelector('[data-mcp-action="remove"]')!);
    fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Cancel' }));
    expect(screen.queryByRole('dialog')).toBeNull();
    expect((await loadMcpLocalState(uid)).servers).toHaveLength(1);
    expect(events('mcp_server_removed')).toEqual([]);
  });
});

describe('feature switch (mcpRuntimeConfig.enabled = false)', () => {
  it('this page does not exist: nothing is rendered and the user is sent back to settings', () => {
    mocks.runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK, enabled: false };
    seedThree();
    const { container } = renderWithIntl(<McpServersPage />);
    expect(container.innerHTML).toBe('');
    expect(mocks.replace).toHaveBeenCalledWith('/settings');
  });
});
