/**
 * The page origin is set to public https: on the web the CIMD `client_id` and the redirect address are
 * derived from the current origin, and jsdom's default `http://localhost` origin does not use CIMD.
 * @vitest-environment-options { "url": "https://app.example.com/" }
 */
// Add-server dialog x real MCP store (fake-indexeddb) x the frozen mock server.
// Everything below the UI is the production path: store.addServer -> McpAddCoordinator -> probe /
// authorize / persist. Only two things are stand-ins: the transport terminates TLS at the fetch layer
// (see mock-server-kit), and a script plays the browser for the authorization window.

import 'fake-indexeddb/auto';
import { act, cleanup, fireEvent, screen, waitFor, within } from '@testing-library/react';
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { MCP_RUNTIME_CONFIG_FALLBACK, type McpRuntimeConfig } from '@oriveo/core/mcp/index';

const mocks = vi.hoisted(() => ({
  trackEvent: vi.fn(),
  runtimeConfig: null as McpRuntimeConfig | null,
}));
vi.mock('next-intl', async () => await import('use-intl'));
vi.mock('../../../lib/core/telemetry', () => ({ trackEvent: mocks.trackEvent }));
vi.mock('../../../lib/core/metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../lib/core/metadata/metadata-client')>()),
  getMcpRuntimeConfig: () => mocks.runtimeConfig,
}));

import { loadMcpLocalState } from '../../../lib/core/mcp/mcp-idb';
import { __setMcpTransportForTests, getMcpCredentialStore, useMcpStore } from '../../../lib/core/mcp/mcp-store';
import { McpAddServerDialog } from '../McpAddServerDialog';
import { IntlProvider } from 'use-intl';
import enMessages from '../../../messages/en.json';
import { renderWithIntl } from './mcp-test-kit';
import { fakeAuthorizationWindow, killAllMockServers, startMockServer, type MockServer } from './mock-server-kit';

let uidCounter = 0;
let uid = '';
let mock: MockServer | null = null;

async function useMock(...flags: string[]): Promise<MockServer> {
  mock = await startMockServer(...flags);
  __setMcpTransportForTests(mock.transport);
  return mock;
}

function renderDialog(props: Partial<Parameters<typeof McpAddServerDialog>[0]> = {}) {
  const onClose = vi.fn();
  const onAdded = vi.fn();
  const { unmount } = renderWithIntl(<McpAddServerDialog open onClose={onClose} onAdded={onAdded} {...props} />);
  return { onClose, onAdded, unmount };
}

const dialog = () => screen.getByRole('dialog');
const view = () => dialog().querySelector('[data-mcp-add]')?.getAttribute('data-mcp-add');
const urlField = () => dialog().querySelector('[data-mcp-field="url"]') as HTMLInputElement;
const click = (name: string | RegExp) => fireEvent.click(within(dialog()).getByRole('button', { name }));
const events = (name: string) => mocks.trackEvent.mock.calls.filter(([event]) => event === name).map(([, props]) => props);

async function connect(url: string) {
  fireEvent.change(urlField(), { target: { value: url } });
  await act(async () => {
    click('Connect');
  });
}

async function stored() {
  return loadMcpLocalState(uid);
}

/** Adds still in flight. Unmounting the dialog cancels them (recording one event each): wait for them to settle before the next case so they do not leak into it. */
const inFlightAdds = new Set<Promise<unknown>>();
const realAddServer = useMcpStore.getState().addServer;

beforeEach(async () => {
  uidCounter += 1;
  uid = `uid-add-dialog-${uidCounter}`;
  mocks.trackEvent.mockReset();
  mocks.runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK };
  useMcpStore.getState().reset();
  useMcpStore.setState({
    addServer: (input) => {
      const pending = realAddServer(input);
      inFlightAdds.add(pending);
      void pending.finally(() => inFlightAdds.delete(pending)).catch(() => {});
      return pending;
    },
  });
  await useMcpStore.getState().hydrate(uid);
});

afterEach(async () => {
  cleanup();
  await Promise.allSettled([...inFlightAdds]);
  // Let the part after `await addServer(...)` in the dialog (recording the event) finish.
  await new Promise((resolve) => setTimeout(resolve, 0));
  useMcpStore.setState({ addServer: realAddServer });
  mock?.stop();
  mock = null;
  __setMcpTransportForTests(null);
});
afterAll(killAllMockServers);

describe('entering the address', () => {
  it('has only address and name with no sign-in method field, explains that sign-in happens in a new window, and disables the primary button while the address is empty', () => {
    renderDialog();
    expect(view()).toBe('form');
    expect(within(dialog()).getByRole('heading', { name: 'Add server' })).not.toBeNull();
    expect(within(dialog()).getByText('Paste the address of an MCP server')).not.toBeNull();
    expect(Array.from(dialog().querySelectorAll('input')).map((input) => input.closest('label')?.querySelector('span')?.textContent)).toEqual(['Server address', 'Name (optional)']);
    // The sign-in method is decided by probing: the form has no selector and no token field.
    expect(within(dialog()).queryAllByRole('radio')).toEqual([]);
    expect(within(dialog()).queryByText('Sign-in method')).toBeNull();
    expect(within(dialog()).queryByPlaceholderText('Paste token')).toBeNull();
    expect(within(dialog()).getByText('If the server asks you to sign in, its own sign-in page opens in a new window. Oriveo never sees your password.')).not.toBeNull();
    expect((within(dialog()).getByRole('button', { name: 'Connect' }) as HTMLButtonElement).disabled).toBe(true);
    fireEvent.change(urlField(), { target: { value: 'https://mcp.example.com/mcp' } });
    expect((within(dialog()).getByRole('button', { name: 'Connect' }) as HTMLButtonElement).disabled).toBe(false);
  });
});

describe('malformed address', () => {
  it.each([
    ['http://mcp.example.com/mcp', 'Enter a full address that starts with https://'],
    ['not a url', 'Enter a full address that starts with https://'],
    ['https://user:pass@mcp.example.com/mcp', "The address can't include a username or password. Remove them and sign in with an access token instead."],
  ])('%s: stays on the form, shows the error under the field and sends no request', async (url, message) => {
    const server = await useMock('--mode=stateless');
    renderDialog();
    await connect(url);
    expect(view()).toBe('form');
    expect(within(dialog()).getByRole('alert').textContent).toBe(message);
    expect(urlField().getAttribute('aria-invalid')).toBe('true');
    expect((await server.state()).calls).toEqual({ toolsList: 0, toolsCall: 0, discover: 0, initialize: 0 });
    expect((await stored()).servers).toEqual([]);
    expect(events('mcp_server_add_result')).toEqual([{ outcome: 'invalid_url', authKind: 'auto', protocolGeneration: 'none' }]);
    // The error disappears once the address is edited
    fireEvent.change(urlField(), { target: { value: 'https://mcp.example.com/mcp' } });
    expect(within(dialog()).queryByRole('alert')).toBeNull();
  });
});

describe('server without sign-in: connect, confirm default permissions, done', () => {
  it('stops at confirming permissions after reading the tools, accepts them only on Done, and defaults read-only tools to run automatically and the rest to ask every time', async () => {
    const server = await useMock('--mode=stateless');
    const { onClose, onAdded } = renderDialog();
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('review'));

    expect(dialog().querySelector('[data-tone="success"]')?.textContent).toBe('Connected');
    expect(within(dialog()).getByText('2 tools')).not.toBeNull();
    expect(within(dialog()).getByText('Default permissions')).not.toBeNull();
    // Grouping comes from the server's own declaration; tool titles are the server's text, untranslated
    expect(within(dialog()).getByText('Weather Information Provider · 1')).not.toBeNull();
    expect(within(dialog()).getByText('Create Issue · 1')).not.toBeNull();
    expect((within(dialog()).getByRole('combobox', { name: 'Read only' }) as HTMLSelectElement).value).toBe('auto');
    expect((within(dialog()).getByRole('combobox', { name: 'Changes data' }) as HTMLSelectElement).value).toBe('ask');
    // Before Done is clicked these tools are still quarantined and none of them is sent to the model
    expect((await stored()).snapshots[useMcpStore.getState().servers[0].id].every((tool) => tool.pendingReview)).toBe(true);

    await act(async () => {
      click('Done');
    });
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    const local = await stored();
    expect(local.servers).toHaveLength(1);
    const id = local.servers[0].id;
    expect(onAdded).toHaveBeenCalledWith(id);
    expect(local.snapshots[id].map((tool) => [tool.toolName, tool.pendingReview])).toEqual([['create_issue', false], ['get_weather', false]]);
    expect(local.permissions[id]).toEqual({ get_weather: 'auto', create_issue: 'ask' });
    expect(local.connections[id]).toMatchObject({ status: 'connected', generation: 'stateless' });
    expect(events('mcp_server_add_result')).toEqual([{ outcome: 'added', authKind: 'auto', protocolGeneration: 'stateless' }]);
    // No sign-in, so no sign-in event
    expect(events('mcp_auth_result')).toEqual([]);
  });

  it('persists the permissions as changed on the confirm-permissions step', async () => {
    const server = await useMock('--mode=session');
    renderDialog();
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('review'));
    // A legacy server reports its own name: the title uses it
    expect(within(dialog()).getByText('OriveoMockServer')).not.toBeNull();
    fireEvent.change(within(dialog()).getByRole('combobox', { name: 'Changes data' }), { target: { value: 'off' } });
    fireEvent.change(within(dialog()).getByRole('combobox', { name: 'Read only' }), { target: { value: 'ask' } });
    await act(async () => {
      click('Done');
    });
    await waitFor(async () => {
      const local = await stored();
      expect(local.permissions[local.servers[0].id]).toEqual({ get_weather: 'ask', create_issue: 'off' });
    });
    expect(events('mcp_server_add_result')).toEqual([{ outcome: 'added', authKind: 'auto', protocolGeneration: 'session' }]);
  });

  it('treats closing the dialog on the confirm-permissions step as abandoning the add and keeps no server record, snapshots or credentials', async () => {
    const server = await useMock('--mode=stateless');
    const { onClose, onAdded } = renderDialog();
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('review'));
    await act(async () => {
      click('Cancel');
    });
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onAdded).not.toHaveBeenCalled();
    await waitFor(async () => {
      const local = await stored();
      expect(local.servers).toEqual([]);
      expect(local.snapshots).toEqual({});
    });
    expect(useMcpStore.getState().servers).toEqual([]);
  });
});

describe('browser sign-in', () => {
  it.each([
    ['oauth-cimd', 'cimd', 0],
    ['oauth-dcr', 'dcr', 1],
  ] as const)('%s: the pre-sign-in notice is a gate, nothing is registered and no window opens before Continue, and the window opens synchronously in that click', async (mode, registration, registered) => {
    const server = await useMock(`--mode=${mode}`);
    const authWindow = fakeAuthorizationWindow(server);
    const { onClose } = renderDialog({ preopened: authWindow });
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('authPrompt'));

    // The host name of the sign-in page must be shown
    expect(within(dialog()).getByRole('heading', { name: 'Sign in to 127.0.0.1' })).not.toBeNull();
    expect(within(dialog()).getByTestId('mcp-auth-host').textContent).toBe('127.0.0.1');
    expect(within(dialog()).getByText("Make sure the sign-in page's domain is a service you recognize.")).not.toBeNull();
    expect(within(dialog()).getByText('Sign-in needed for 127.0.0.1')).not.toBeNull();
    // Before the gate: no client registered, no authorization code issued, no window opened
    expect(await server.state()).toMatchObject({ clientsRegistered: 0, codesIssued: 0 });
    expect(authWindow.preopened).toBe(0);
    expect(authWindow.opened).toEqual([]);

    await act(async () => {
      click('Continue');
      // When the click handler returns the window is already open (synchronously) and the authorization URL is not known yet
      expect(authWindow.preopened).toBe(1);
    });
    await waitFor(() => expect(view()).toBe('review'));
    expect(authWindow.opened).toHaveLength(1);
    expect(await server.state()).toMatchObject({ clientsRegistered: registered, codesIssued: 1, tokensIssued: 1 });

    await act(async () => {
      click('Done');
    });
    await waitFor(() => expect(onClose).toHaveBeenCalled());
    const id = (await stored()).servers[0].id;
    // Credentials live only in the credential store: the server record has no token field at all
    expect(await getMcpCredentialStore(uid).load(id, uid)).toMatchObject({ accessToken: expect.any(String) });
    expect(JSON.stringify((await stored()).servers)).not.toMatch(/token|secret/i);
    expect(events('mcp_auth_result')).toEqual([{ outcome: 'success', registration, trigger: 'add' }]);
    expect(events('mcp_server_add_result')).toEqual([{ outcome: 'added', authKind: 'auto', protocolGeneration: 'stateless' }]);
  });

  it('stays on the pre-sign-in notice and asks to allow pop-ups when the browser blocks the sign-in window, registers no client, and signs in normally on Continue once pop-ups are allowed', async () => {
    const server = await useMock('--mode=oauth-dcr');
    const authWindow = fakeAuthorizationWindow(server);
    let blocked = true;
    const preopen = authWindow.preopen.bind(authWindow);
    authWindow.preopen = () => {
      if (blocked) return false;
      return preopen();
    };
    renderDialog({ preopened: authWindow });
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('authPrompt'));

    await act(async () => {
      click('Continue');
    });
    expect(view()).toBe('authPrompt');
    expect(within(dialog()).getByRole('alert').textContent).toBe('Your browser blocked the sign-in window. Allow pop-ups for this site, then try again.');
    // The gate did not open: nothing was left on the third party's side.
    expect(await server.state()).toMatchObject({ clientsRegistered: 0, codesIssued: 0 });
    expect(authWindow.opened).toEqual([]);

    blocked = false;
    await act(async () => {
      click('Continue');
    });
    await waitFor(() => expect(view()).toBe('review'));
    expect(await server.state()).toMatchObject({ clientsRegistered: 1, codesIssued: 1, tokensIssued: 1 });
  });

  it('closes the dialog on Cancel in the pre-sign-in notice and leaves nothing behind, locally or on the third party side', async () => {
    const server = await useMock('--mode=oauth-dcr');
    const authWindow = fakeAuthorizationWindow(server);
    const { onClose } = renderDialog({ preopened: authWindow });
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('authPrompt'));
    await act(async () => {
      click('Cancel');
    });
    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1));
    expect(await server.state()).toMatchObject({ clientsRegistered: 0, codesIssued: 0, tokensIssued: 0 });
    expect(authWindow.preopened).toBe(0);
    expect((await stored()).servers).toEqual([]);
  });

  it('explains the server was not added when the sign-in window is closed before finishing, and offers to sign in again', async () => {
    const server = await useMock('--mode=oauth-cimd');
    const closing = fakeAuthorizationWindow(server, 'close');
    renderDialog({ preopened: closing });
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('authPrompt'));
    await act(async () => {
      click('Continue');
    });
    await waitFor(() => expect(view()).toBe('authCancelled'));
    expect(dialog().querySelector('[data-tone="warning"]')?.textContent).toBe('Sign-in not finished');
    expect(within(dialog()).getByRole('alert').textContent).toBe("Sign-in wasn't completedThe sign-in window was closed, or the service didn't approve the request. The server hasn't been added.");
    expect((await stored()).servers).toEqual([]);
    expect(events('mcp_server_add_result')).toEqual([{ outcome: 'auth_cancelled', authKind: 'auto', protocolGeneration: 'none' }]);
    expect(events('mcp_auth_result')).toEqual([{ outcome: 'cancelled', registration: 'cimd', trigger: 'add' }]);
    expect(closing.discarded).toBe(1);

    // "Sign in again" starts over: back at the pre-sign-in notice (the user's consent is still required)
    await act(async () => {
      click('Sign in again');
    });
    await waitFor(() => expect(view()).toBe('authPrompt'));
  });
});

describe('access token required, and token errors', () => {
  it('lets the user paste a token in place and connect when the server requires sign-in but has no automatic sign-in, and shows a rejected token as an error under the field', async () => {
    const server = await useMock('--mode=token', '--token=good-token');
    const { onClose } = renderDialog();
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('needsToken'));
    expect(dialog().querySelector('[data-tone="warning"]')?.textContent).toBe('Token needed');
    expect(within(dialog()).getByRole('alert').textContent).toBe("This server doesn't support automatic sign-inCreate an access token in the service's settings and paste it below.");
    expect((within(dialog()).getByRole('button', { name: 'Connect' }) as HTMLButtonElement).disabled).toBe(true);

    fireEvent.change(within(dialog()).getByPlaceholderText('Paste token'), { target: { value: 'wrong-token' } });
    await act(async () => {
      click('Connect');
    });
    await waitFor(() => expect(within(dialog()).getByRole('alert').textContent).toBe("The server didn't accept this token."));
    // The token field is on the "access token required" step itself: the error stays here instead of
    // falling back to the form that has only address and name.
    expect(view()).toBe('needsToken');
    expect((await stored()).servers).toEqual([]);

    fireEvent.change(within(dialog()).getByPlaceholderText('Paste token'), { target: { value: 'good-token' } });
    await act(async () => {
      click('Connect');
    });
    await waitFor(() => expect(view()).toBe('review'));
    await act(async () => {
      click('Done');
    });
    await waitFor(() => expect(onClose).toHaveBeenCalled());
    const local = await stored();
    expect(local.servers[0]).toMatchObject({ authKind: 'token' });
    expect(await getMcpCredentialStore(uid).load(local.servers[0].id, uid)).toMatchObject({ pastedToken: 'good-token' });
    expect(events('mcp_server_add_result').map((event) => event.outcome)).toEqual(['needs_token', 'token_rejected', 'added']);
    // The token never goes into an event
    expect(JSON.stringify(mocks.trackEvent.mock.calls)).not.toContain('good-token');
  });
});

describe('unreachable, and not an MCP server', () => {
  it('offers Retry and Edit address when unreachable and keeps no record', async () => {
    const server = await useMock('--mode=stateless');
    const endpoint = server.endpoint;
    server.stop();
    renderDialog();
    await connect(endpoint);
    await waitFor(() => expect(view()).toBe('unreachable'));
    expect(dialog().querySelector('[data-tone="danger"]')?.textContent).toBe("Can't connect");
    expect(within(dialog()).getByRole('alert').textContent).toContain("Can't reach this server");
    expect(within(dialog()).getByRole('button', { name: 'Try again' })).not.toBeNull();
    expect((await stored()).servers).toEqual([]);
    expect(events('mcp_server_add_result')).toEqual([{ outcome: 'unreachable', authKind: 'auto', protocolGeneration: 'none' }]);
    click('Edit address');
    expect(view()).toBe('form');
    expect(urlField().value).toBe(endpoint);
  });

  it('hints that a missing path is the usual cause when the address responds but is not MCP, and offers only Edit address', async () => {
    const server = await useMock('--mode=stateless');
    renderDialog();
    await connect(`${server.httpsOrigin}/not-mcp`);
    await waitFor(() => expect(view()).toBe('notMcp'));
    expect(dialog().querySelector('[data-tone="warning"]')?.textContent).toBe('Not recognized');
    expect(within(dialog()).getByRole('alert').textContent).toContain("This address isn't an MCP server");
    expect(within(dialog()).queryByRole('button', { name: 'Try again' })).toBeNull();
    expect((await stored()).servers).toEqual([]);
    expect(events('mcp_server_add_result')).toEqual([{ outcome: 'not_mcp', authKind: 'auto', protocolGeneration: 'none' }]);
  });
});

describe('other terminal states', () => {
  it('reports the server limit before probing and sends no request', async () => {
    const server = await useMock('--mode=stateless');
    mocks.runtimeConfig = { ...MCP_RUNTIME_CONFIG_FALLBACK, maxServers: 1 };
    const first = renderDialog();
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('review'));
    await act(async () => {
      click('Done');
    });
    await waitFor(() => expect(first.onClose).toHaveBeenCalled());
    first.unmount();
    const before = (await server.state()).calls;

    renderDialog();
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('limitReached'));
    expect(within(dialog()).getByRole('alert').textContent).toBe("You've reached the server limitYou can connect up to 1 servers. Remove one you no longer use, then add this one.");
    expect((await server.state()).calls).toEqual(before);
    expect((await stored()).servers).toHaveLength(1);
    expect(events('mcp_server_add_result').at(-1)).toEqual({ outcome: 'limit_reached', authKind: 'auto', protocolGeneration: 'none' });
  });

  it('treats closing the dialog while connecting as a cancel, so a later server response does not add a server', async () => {
    const server = await useMock('--mode=slow', '--delay-ms=300');
    const { onClose } = renderDialog();
    await connect(server.endpoint);
    expect(view()).toBe('connecting');
    await act(async () => {
      click('Cancel');
    });
    expect(onClose).toHaveBeenCalledTimes(1);
    await new Promise((resolve) => setTimeout(resolve, 700));
    expect((await stored()).servers).toEqual([]);
    expect(useMcpStore.getState().servers).toEqual([]);
  });

  it('also cancels when the dialog is unmounted while connecting (page change, no Cancel click), so no server is added later', async () => {
    const server = await useMock('--mode=slow', '--delay-ms=300');
    const { unmount } = renderDialog();
    await connect(server.endpoint);
    expect(view()).toBe('connecting');
    unmount();
    await new Promise((resolve) => setTimeout(resolve, 700));
    expect((await stored()).servers).toEqual([]);
    expect(useMcpStore.getState().servers).toEqual([]);
    expect(events('mcp_server_add_result').map((event) => event.outcome)).toEqual(['cancelled']);
  });

  it('treats an unmount or an outside close on the confirm-permissions step as abandoning the add and keeps no record, snapshots or credentials', async () => {
    const server = await useMock('--mode=token', '--token=good-token');
    const reachReview = async () => {
      await connect(server.endpoint);
      await waitFor(() => expect(view()).toBe('needsToken'));
      fireEvent.change(within(dialog()).getByPlaceholderText('Paste token'), { target: { value: 'good-token' } });
      await act(async () => {
        click('Connect');
      });
      await waitFor(() => expect(view()).toBe('review'));
      expect((await stored()).servers).toHaveLength(1);
    };
    const expectNothingLeft = () =>
      waitFor(async () => {
        const local = await stored();
        expect(local.servers).toEqual([]);
        expect(local.snapshots).toEqual({});
        expect(await getMcpCredentialStore(uid).load('any', uid)).toBeNull();
        expect(useMcpStore.getState().servers).toEqual([]);
      });

    // 1. Unmount
    const first = renderDialog();
    await reachReview();
    const firstId = (await stored()).servers[0].id;
    first.unmount();
    await expectNothingLeft();
    expect(await getMcpCredentialStore(uid).reload(firstId, uid)).toBeNull();

    // 2. The parent sets open to false (without going through the dialog's own Cancel)
    const onClose = vi.fn();
    const second = renderWithIntl(<McpAddServerDialog open onClose={onClose} />);
    await reachReview();
    const secondId = (await stored()).servers[0].id;
    second.rerender(
      <IntlProvider locale="en" messages={enMessages} timeZone="UTC">
        <McpAddServerDialog open={false} onClose={onClose} />
      </IntlProvider>,
    );
    await expectNothingLeft();
    expect(await getMcpCredentialStore(uid).reload(secondId, uid)).toBeNull();
  });

  it('keeps the server when the dialog closes after Done was clicked', async () => {
    const server = await useMock('--mode=stateless');
    const { unmount } = renderDialog();
    await connect(server.endpoint);
    await waitFor(() => expect(view()).toBe('review'));
    // Unmounted right after the click, before the persistence inside Done has even finished: the user has
    // already decided, so this must not be treated as abandoning.
    click('Done');
    unmount();
    await waitFor(async () => expect((await stored()).servers[0]).not.toHaveProperty('pendingAdd'));
    await new Promise((resolve) => setTimeout(resolve, 50));
    const local = await stored();
    expect(local.servers).toHaveLength(1);
    expect(local.servers[0]).not.toHaveProperty('pendingAdd');
  });

  it('explains the reason and keeps no record when local storage fails', async () => {
    renderDialog();
    const original = useMcpStore.getState().addServer;
    // How a persistence failure arises is covered by the core module and mcp-idb tests; this only checks
    // how the UI presents that terminal state.
    useMcpStore.setState({ addServer: async (input) => { await input.progress?.({ kind: 'connecting' }); return { kind: 'saveFailed' }; } });
    try {
      await connect('https://mcp.example.com/mcp');
      await waitFor(() => expect(view()).toBe('saveFailed'));
      expect(within(dialog()).getByRole('alert').textContent).toContain("Couldn't save this server");
      expect(within(dialog()).getByRole('button', { name: 'Close' })).not.toBeNull();
      expect(events('mcp_server_add_result')).toEqual([{ outcome: 'save_failed', authKind: 'auto', protocolGeneration: 'none' }]);
    } finally {
      useMcpStore.setState({ addServer: original });
    }
  });
});
