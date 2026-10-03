import { render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { McpOauthCallback } from './McpOauthCallback';
import { MCP_OAUTH_CALLBACK_CHANNEL, listenForMcpOauthCallback } from './callback-handoff';
import { FakeChannelHub } from './callback-test-doubles';

// The next-intl mock of the test environment returns keys as is (setup.ts), so assertions are on keys rather than translated text.

const CALLBACK_PATH = '/mcp/oauth/callback';

function setOpener(value: unknown) {
  Object.defineProperty(window, 'opener', { value, configurable: true });
}

function visitCallback(query: string) {
  window.history.replaceState(null, '', `${CALLBACK_PATH}${query}`);
}

/** Replaces the global BroadcastChannel with a double (jsdom does not implement it) and records the channel names opened. */
function installBroadcastChannel(): { hub: FakeChannelHub; names: string[] } {
  const hub = new FakeChannelHub();
  const names: string[] = [];
  vi.stubGlobal(
    'BroadcastChannel',
    function FakeBroadcastChannel(name: string) {
      names.push(name);
      return hub.open();
    },
  );
  return { hub, names };
}

describe('McpOauthCallback', () => {
  let stopListening: (() => void) | undefined;

  beforeEach(() => {
    setOpener(null);
  });

  afterEach(() => {
    stopListening?.();
    stopListening = undefined;
    setOpener(null);
    window.history.replaceState(null, '', '/');
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it('starting page waiting: handed back over BroadcastChannel (window.opener is null), shows "done" and tries to close itself', async () => {
    const { names } = installBroadcastChannel();
    const close = vi.spyOn(window, 'close').mockImplementation(() => {});
    const onResult = vi.fn();
    stopListening = listenForMcpOauthCallback({
      state: 'xyz',
      origin: window.location.origin,
      messageTarget: window,
      onResult,
    });
    visitCallback('?code=abc&state=xyz&iss=https%3A%2F%2Fauth.example.com');

    render(<McpOauthCallback />);

    expect(await screen.findByText('completed')).toBeTruthy();
    expect(screen.getByText('completedDescription')).toBeTruthy();
    expect(screen.queryByText('returnToApp')).toBeNull();
    expect(onResult).toHaveBeenCalledTimes(1);
    expect(onResult).toHaveBeenCalledWith({ code: 'abc', state: 'xyz', iss: 'https://auth.example.com' });
    expect(close).toHaveBeenCalled();
    expect(names.every((name) => name === MCP_OAUTH_CALLBACK_CHANNEL)).toBe(true);
    expect(names.length).toBeGreaterThanOrEqual(2);
  });

  it('after the handoff the address bar no longer contains code / state', async () => {
    installBroadcastChannel();
    vi.spyOn(window, 'close').mockImplementation(() => {});
    stopListening = listenForMcpOauthCallback({
      state: 'xyz',
      origin: window.location.origin,
      messageTarget: window,
      onResult: () => {},
    });
    visitCallback('?code=abc&state=xyz#fragment');

    render(<McpOauthCallback />);

    await screen.findByText('completed');
    expect(window.location.pathname).toBe(CALLBACK_PATH);
    expect(window.location.search).toBe('');
    expect(window.location.hash).toBe('');
    expect(window.location.href).not.toContain('abc');
  });

  it('no page waiting (the tab that started the authorization is gone): after about 1.5 seconds shows "please return to the app", and the address bar is cleared as well', async () => {
    installBroadcastChannel();
    const close = vi.spyOn(window, 'close').mockImplementation(() => {});
    visitCallback('?code=abc&state=xyz');

    const { container } = render(<McpOauthCallback />);

    // Nothing is rendered while waiting for the acknowledgement.
    expect(container.innerHTML).toBe('');
    expect(await screen.findByText('returnToApp', undefined, { timeout: 3000 })).toBeTruthy();
    expect(screen.getByText('returnToAppDescription')).toBeTruthy();
    expect(screen.queryByText('completed')).toBeNull();
    expect(close).not.toHaveBeenCalled();
    expect(window.location.search).toBe('');
  });

  it('another authorization flow waiting (different state): not claimed, shows "please return to the app"', async () => {
    installBroadcastChannel();
    const onResult = vi.fn();
    stopListening = listenForMcpOauthCallback({
      state: 'another-flow',
      origin: window.location.origin,
      messageTarget: window,
      onResult,
    });
    visitCallback('?code=abc&state=xyz');

    render(<McpOauthCallback />);

    expect(await screen.findByText('returnToApp', undefined, { timeout: 3000 })).toBeTruthy();
    expect(onResult).not.toHaveBeenCalled();
  });

  it('opener channel fallback: without BroadcastChannel the result goes back through window.opener, with the site origin as targetOrigin', async () => {
    vi.stubGlobal('BroadcastChannel', undefined);
    const close = vi.spyOn(window, 'close').mockImplementation(() => {});
    const postMessage = vi.fn((message: { params: Record<string, string> }, targetOrigin: string) => {
      // The starting page acknowledges after claiming (in production listenForMcpOauthCallback sends it; only the callback page side is checked here).
      window.dispatchEvent(
        new MessageEvent('message', {
          data: { type: 'oriveo:mcp-oauth-callback-ack', state: message.params.state },
          origin: targetOrigin,
        }),
      );
    });
    setOpener({ closed: false, postMessage });
    visitCallback('?code=abc&state=xyz');

    render(<McpOauthCallback />);

    await waitFor(() => expect(postMessage).toHaveBeenCalledTimes(1));
    expect(postMessage).toHaveBeenCalledWith(
      { type: 'oriveo:mcp-oauth-callback', params: { code: 'abc', state: 'xyz' } },
      window.location.origin,
    );
    expect(await screen.findByText('completed')).toBeTruthy();
    expect(close).toHaveBeenCalled();
  });

  it('a closed opener gets no delivery and is treated as nobody claiming', async () => {
    vi.stubGlobal('BroadcastChannel', undefined);
    const postMessage = vi.fn();
    setOpener({ closed: true, postMessage });
    visitCallback('?code=abc&state=xyz');

    render(<McpOauthCallback />);

    expect(await screen.findByText('returnToApp', undefined, { timeout: 3000 })).toBeTruthy();
    expect(postMessage).not.toHaveBeenCalled();
  });

  it('re-rendering neither repeats the handoff nor overwrites a success with "please return to the app"', async () => {
    installBroadcastChannel();
    vi.spyOn(window, 'close').mockImplementation(() => {});
    const onResult = vi.fn();
    stopListening = listenForMcpOauthCallback({
      state: 'xyz',
      origin: window.location.origin,
      messageTarget: window,
      onResult,
    });
    visitCallback('?code=abc&state=xyz');

    const { rerender } = render(<McpOauthCallback />);
    await screen.findByText('completed');
    rerender(<McpOauthCallback />);
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(screen.getByText('completed')).toBeTruthy();
    expect(onResult).toHaveBeenCalledTimes(1);
  });
});
