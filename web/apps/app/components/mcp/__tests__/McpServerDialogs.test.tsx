/**
 * The page origin is set to public https: on the web the CIMD `client_id` and the redirect address are
 * derived from the current origin, and jsdom's default `http://localhost` origin does not use CIMD.
 * @vitest-environment-options { "url": "https://app.example.com/" }
 */
// Reauthorization and tool-change confirmation x real MCP store (fake-indexeddb) x the frozen mock
// server. The server is first persisted through the production add flow (store.addServer) and then
// pushed into the state under test.

import 'fake-indexeddb/auto';
import { act, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MCP_RUNTIME_CONFIG_FALLBACK } from '@oriveo/core/mcp/index';

const mocks = vi.hoisted(() => ({ trackEvent: vi.fn() }));
vi.mock('next-intl', async () => await import('use-intl'));
vi.mock('../../../lib/core/telemetry', () => ({ trackEvent: mocks.trackEvent }));
vi.mock('../../../lib/core/metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/metadata/metadata-client')>()),
  getMcpRuntimeConfig: () => ({ ...MCP_RUNTIME_CONFIG_FALLBACK }),
}));

import { loadMcpLocalState } from '../../../lib/core/mcp/mcp-idb';
import { acceptMcpAddedTools, refreshMcpServerTools } from '../../../lib/core/mcp/mcp-server-actions';
import { __setMcpTransportForTests, getMcpCredentialStore, useMcpStore } from '../../../lib/core/mcp/mcp-store';
import { McpReauthDialog } from '../McpReauthDialog';
import { McpToolsChangedDialog } from '../McpToolsChangedDialog';
import { renderWithIntl } from './mcp-test-kit';
import { fakeAuthorizationWindow, killAllMockServers, startMockServer, type MockServer } from './mock-server-kit';

let uidCounter = 0;
let uid = '';
let mock: MockServer;

/** Adds a server through the production add flow and accepts its tools. Returns the server id. */
async function addServer(options: { authKind?: 'auto' | 'token'; token?: string } = {}): Promise<string> {
  const authWindow = fakeAuthorizationWindow(mock);
  const state = await useMcpStore.getState().addServer({
    url: mock.endpoint,
    authKind: options.authKind ?? 'auto',
    token: options.token ?? null,
    confirmAuthorization: async () => true,
    launcher: authWindow.launcher,
  });
  if (state.kind !== 'review') throw new Error(`add failed: ${state.kind}`);
  await acceptMcpAddedTools(state.review.serverId, state.review.defaultPermissions);
  return state.review.serverId;
}

const server = (id: string) => useMcpStore.getState().servers.find((item) => item.id === id) ?? null;
const dialog = () => screen.getByRole('dialog');
const click = (name: string) => fireEvent.click(within(dialog()).getByRole('button', { name }));
const events = (name: string) => mocks.trackEvent.mock.calls.filter(([event]) => event === name).map(([, props]) => props);

beforeEach(async () => {
  uidCounter += 1;
  uid = `uid-mcp-dialogs-${uidCounter}`;
  mocks.trackEvent.mockReset();
  useMcpStore.getState().reset();
  await useMcpStore.getState().hydrate(uid);
});

afterEach(() => {
  mock?.stop();
  __setMcpTransportForTests(null);
});
afterAll(killAllMockServers);

describe('reauthorization', () => {
  it('shows the pre-sign-in notice (with the sign-in page host name) first for a browser sign-in server, opens the window only on Continue, and restores the connection on success', async () => {
    mock = await startMockServer('--mode=oauth-cimd');
    __setMcpTransportForTests(mock.transport);
    const id = await addServer();
    // The token is no longer valid: the local credentials are gone and the server starts requiring sign-in
    await getMcpCredentialStore(uid).delete(id, uid);
    expect((await refreshMcpServerTools(id)).status).toBe('needsAuth');
    expect(useMcpStore.getState().connections[id].status).toBe('needsAuth');
    const issuedBefore = (await mock.state()).codesIssued;

    const authWindow = fakeAuthorizationWindow(mock);
    const onClose = vi.fn();
    const onAuthorized = vi.fn();
    renderWithIntl(<McpReauthDialog server={server(id)} trigger="mid_loop" onClose={onClose} onAuthorized={onAuthorized} preopened={authWindow} />);
    await waitFor(() => expect(within(dialog()).queryByRole('button', { name: 'Continue' })).not.toBeNull());
    expect(within(dialog()).getByTestId('mcp-auth-host').textContent).toBe('127.0.0.1');
    // Before the user consents: no window opened and no new authorization code
    expect(authWindow.preopened).toBe(0);
    expect((await mock.state()).codesIssued).toBe(issuedBefore);

    await act(async () => {
      click('Continue');
      expect(authWindow.preopened).toBe(1);
    });
    await waitFor(() => expect(onAuthorized).toHaveBeenCalledWith(id));
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(useMcpStore.getState().connections[id].status).toBe('connected');
    expect(await getMcpCredentialStore(uid).load(id, uid)).toMatchObject({ accessToken: expect.any(String) });
    expect(events('mcp_auth_result')).toEqual([{ outcome: 'success', registration: 'cimd', trigger: 'mid_loop' }]);
  });

  it('explains that sign-in did not finish and nothing changed when the window is closed, and allows a retry', async () => {
    mock = await startMockServer('--mode=oauth-cimd');
    __setMcpTransportForTests(mock.transport);
    const id = await addServer();
    await getMcpCredentialStore(uid).delete(id, uid);
    await refreshMcpServerTools(id);

    const onAuthorized = vi.fn();
    renderWithIntl(<McpReauthDialog server={server(id)} trigger="reauth" onClose={vi.fn()} onAuthorized={onAuthorized} preopened={fakeAuthorizationWindow(mock, 'close')} />);
    await waitFor(() => expect(within(dialog()).queryByRole('button', { name: 'Continue' })).not.toBeNull());
    await act(async () => {
      click('Continue');
    });
    await waitFor(() => expect(within(dialog()).getByRole('heading').textContent).toBe("Sign-in wasn't completed"));
    expect(onAuthorized).not.toHaveBeenCalled();
    expect(useMcpStore.getState().connections[id].status).toBe('needsAuth');
    expect(events('mcp_auth_result')).toEqual([{ outcome: 'cancelled', registration: 'cimd', trigger: 'reauth' }]);
    expect(within(dialog()).getByRole('button', { name: 'Try again' })).not.toBeNull();
  });

  it('stays on the pre-sign-in notice and asks to allow pop-ups when the browser blocks the window, without counting a failed sign-in, and continues once pop-ups are allowed', async () => {
    mock = await startMockServer('--mode=oauth-cimd');
    __setMcpTransportForTests(mock.transport);
    const id = await addServer();
    await getMcpCredentialStore(uid).delete(id, uid);
    await refreshMcpServerTools(id);

    const authWindow = fakeAuthorizationWindow(mock);
    const preopen = authWindow.preopen.bind(authWindow);
    let blocked = true;
    authWindow.preopen = () => (blocked ? false : preopen());
    const onAuthorized = vi.fn();
    renderWithIntl(<McpReauthDialog server={server(id)} trigger="reauth" onClose={vi.fn()} onAuthorized={onAuthorized} preopened={authWindow} />);
    await waitFor(() => expect(within(dialog()).queryByRole('button', { name: 'Continue' })).not.toBeNull());
    await act(async () => {
      click('Continue');
    });
    expect(within(dialog()).getByRole('alert').textContent).toBe('Your browser blocked the sign-in window. Allow pop-ups for this site, then try again.');
    expect(within(dialog()).getByTestId('mcp-auth-host')).not.toBeNull();
    expect(authWindow.opened).toEqual([]);
    expect(events('mcp_auth_result')).toEqual([]);

    blocked = false;
    await act(async () => {
      click('Continue');
    });
    await waitFor(() => expect(onAuthorized).toHaveBeenCalledWith(id));
    expect(events('mcp_auth_result')).toEqual([{ outcome: 'success', registration: 'cimd', trigger: 'reauth' }]);
  });

  it('shows a token field for an access-token server, does not save a token the server rejects and swaps in one it accepts', async () => {
    mock = await startMockServer('--mode=token', '--token=token-v1');
    __setMcpTransportForTests(mock.transport);
    const id = await addServer({ authKind: 'token', token: 'token-v1' });
    // The service rotated the token
    mock.stop();
    mock = await startMockServer('--mode=token', '--token=token-v2');
    __setMcpTransportForTests(mock.transport);
    // The address changed with the port: point the record at the new address (ports are random in tests;
    // in production the address does not change)
    useMcpStore.setState({ servers: useMcpStore.getState().servers.map((item) => ({ ...item, url: mock.endpoint })) });

    const onAuthorized = vi.fn();
    renderWithIntl(<McpReauthDialog server={server(id)} trigger="reauth" onClose={vi.fn()} onAuthorized={onAuthorized} />);
    await waitFor(() => expect(within(dialog()).queryByPlaceholderText('Paste token')).not.toBeNull());
    expect(within(dialog()).getByRole('heading').textContent).toBe('Paste a new access token');

    fireEvent.change(within(dialog()).getByPlaceholderText('Paste token'), { target: { value: 'nope' } });
    await act(async () => {
      click('Save');
    });
    await waitFor(() => expect(within(dialog()).getByRole('alert').textContent).toBe("The server didn't accept this token."));
    expect(await getMcpCredentialStore(uid).load(id, uid)).toMatchObject({ pastedToken: 'token-v1' });

    fireEvent.change(within(dialog()).getByPlaceholderText('Paste token'), { target: { value: 'token-v2' } });
    await act(async () => {
      click('Save');
    });
    await waitFor(() => expect(onAuthorized).toHaveBeenCalledWith(id));
    expect(await getMcpCredentialStore(uid).load(id, uid)).toMatchObject({ pastedToken: 'token-v2' });
    expect(events('mcp_auth_result')).toEqual([
      { outcome: 'failed', registration: 'none', trigger: 'reauth' },
      { outcome: 'success', registration: 'none', trigger: 'reauth' },
    ]);
    expect(JSON.stringify(mocks.trackEvent.mock.calls)).not.toContain('token-v');
  });

  it('says plainly that the server is unreachable instead of sending the user to sign in', async () => {
    mock = await startMockServer('--mode=stateless');
    __setMcpTransportForTests(mock.transport);
    const id = await addServer();
    mock.stop();
    renderWithIntl(<McpReauthDialog server={server(id)} trigger="reauth" onClose={vi.fn()} />);
    await waitFor(() => expect(within(dialog()).getByRole('heading').textContent).toBe("Can't reach this server"));
    expect(within(dialog()).queryByRole('button', { name: 'Continue' })).toBeNull();
  });
});

describe('tool-change confirmation', () => {
  // `--mutable-tools`: the mock server advances one round per tools/list it receives (the probe counts
  // too). The add flow uses up rounds 0 and 1 (three tools are persisted), so the next read gets the
  // definitions from round 2 onwards, where the description of get_weather has changed.

  it('quarantines a tool whose description changed, shows the earlier and current descriptions, and releases it on confirm without touching permissions', async () => {
    mock = await startMockServer('--mode=stateless', '--mutable-tools');
    __setMcpTransportForTests(mock.transport);
    const id = await addServer();
    const previous = [...useMcpStore.getState().snapshots[id]];
    expect(previous.map((tool) => tool.toolName).sort()).toEqual(['create_issue', 'get_weather', 'list_issues']);

    const refreshed = await refreshMcpServerTools(id);
    expect(refreshed).toEqual({ status: 'connected', changes: [{ kind: 'changed', toolName: 'get_weather', title: 'Weather Information Provider' }] });
    const afterRefresh = await loadMcpLocalState(uid);
    expect(afterRefresh.snapshots[id].map((tool) => [tool.toolName, tool.pendingReview])).toEqual([
      ['create_issue', false], ['get_weather', true], ['list_issues', false],
    ]);

    const onClose = vi.fn();
    const onPause = vi.fn();
    renderWithIntl(<McpToolsChangedDialog server={server(id)} previous={previous} onClose={onClose} onPause={onPause} />);
    expect(within(dialog()).getByRole('heading').textContent).toBe("127.0.0.1's tools have changed");
    expect(within(dialog()).getByText("For safety, changed tools aren't offered to the model until you confirm.")).not.toBeNull();
    const rows = within(dialog()).getAllByRole('listitem');
    expect(rows.map((row) => row.getAttribute('data-change'))).toEqual(['changed']);
    expect(rows[0].textContent).toBe('Description changedWeather Information ProviderRead only · Run automaticallySee what changed');
    // "View changes": the earlier and current descriptions verbatim (shown exactly as the server provides them)
    fireEvent.click(within(rows[0]).getByRole('button', { name: 'See what changed' }));
    expect(rows[0].textContent).toContain('BeforeGet current weather for a location');
    expect(rows[0].textContent).toContain('NowGet current weather for a location (updated)');

    await act(async () => {
      click('Confirm and keep using');
    });
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    const afterConfirm = await loadMcpLocalState(uid);
    expect(afterConfirm.snapshots[id].every((tool) => !tool.pendingReview)).toBe(true);
    expect(afterConfirm.permissions[id]).toEqual({ get_weather: 'auto', create_issue: 'ask', list_issues: 'auto' });
    expect(onPause).not.toHaveBeenCalled();
  });

  it('keeps the quarantine when what the user saw no longer matches the server (changed again during confirmation), asks for another look and swaps in the latest definition', async () => {
    mock = await startMockServer('--mode=stateless', '--mutable-tools');
    __setMcpTransportForTests(mock.transport);
    const id = await addServer();
    await refreshMcpServerTools(id);
    // What the user is looking at is an older version: the server changed it once more before the confirm click
    const store = useMcpStore.getState();
    await store.saveToolCatalog(
      id,
      store.snapshots[id].map((tool) => (tool.toolName === 'get_weather' ? { ...tool, description: 'An older description', contentHash: 'stale-hash' } : tool)),
      store.permissions[id],
    );

    const onClose = vi.fn();
    renderWithIntl(<McpToolsChangedDialog server={server(id)} onClose={onClose} onPause={vi.fn()} />);
    fireEvent.click(within(dialog()).getByRole('button', { name: 'See what changed' }));
    expect(within(dialog()).getAllByRole('listitem')[0].textContent).toContain('NowAn older description');

    await act(async () => {
      click('Confirm and keep using');
    });
    await waitFor(() => expect(within(dialog()).queryByRole('alert')).not.toBeNull());
    expect(within(dialog()).getByRole('alert').textContent).toBe('Some tools changed again while you were confirming. Take another look.');
    expect(onClose).not.toHaveBeenCalled();
    // The definition the user never saw was not released; what is in front of them now is the server's latest definition
    const local = await loadMcpLocalState(uid);
    expect(local.snapshots[id].find((tool) => tool.toolName === 'get_weather')).toMatchObject({
      pendingReview: true, description: 'Get current weather for a location (updated)',
    });
    expect(within(dialog()).getAllByRole('listitem')[0].textContent).toContain('NowGet current weather for a location (updated)');

    await act(async () => {
      click('Confirm and keep using');
    });
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect((await loadMcpLocalState(uid)).snapshots[id].every((tool) => !tool.pendingReview)).toBe(true);
  });

  it('lists removed tools on the last row and hands Pause this server back to the caller', async () => {
    mock = await startMockServer('--mode=stateless', '--mutable-tools');
    __setMcpTransportForTests(mock.transport);
    const id = await addServer();
    await refreshMcpServerTools(id);
    const onPause = vi.fn();
    renderWithIntl(
      <McpToolsChangedDialog server={server(id)} removed={[{ kind: 'removed', toolName: 'list_projects', title: 'List projects' }]} onClose={vi.fn()} onPause={onPause} />,
    );
    const rows = within(dialog()).getAllByRole('listitem');
    expect(rows.at(-1)?.textContent).toBe('RemovedList projectsNo longer offered by the server');
    click('Pause this server for now');
    expect(onPause).toHaveBeenCalledWith(id);
  });

  it('reports plainly when the server is unreachable on confirm and keeps the quarantine', async () => {
    mock = await startMockServer('--mode=stateless', '--mutable-tools');
    __setMcpTransportForTests(mock.transport);
    const id = await addServer();
    await refreshMcpServerTools(id);
    mock.stop();
    const onClose = vi.fn();
    renderWithIntl(<McpToolsChangedDialog server={server(id)} onClose={onClose} onPause={vi.fn()} />);
    await act(async () => {
      click('Confirm and keep using');
    });
    await waitFor(() => expect(within(dialog()).queryByRole('alert')).not.toBeNull());
    expect(within(dialog()).getByRole('alert').textContent).toBe("Couldn't reach this server. Try again in a moment.");
    expect(onClose).not.toHaveBeenCalled();
    expect((await loadMcpLocalState(uid)).snapshots[id].find((tool) => tool.toolName === 'get_weather')?.pendingReview).toBe(true);
  });
});
