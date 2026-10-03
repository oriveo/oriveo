import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  MCP_OAUTH_CALLBACK_ACK_TIMEOUT_MS,
  MCP_OAUTH_CALLBACK_ACK_TYPE,
  MCP_OAUTH_CALLBACK_CHANNEL,
  MCP_OAUTH_CALLBACK_MESSAGE_TYPE,
  collectCallbackParams,
  deliverCallbackResult,
  listenForMcpOauthCallback,
  scrubCallbackUrl,
} from './callback-handoff';
import { FakeChannelHub, FakeWindow } from './callback-test-doubles';

const ORIGIN = 'https://app.example.com';
const PARAMS = { code: 'auth-code-1', state: 'state-A', iss: 'https://auth.example.com' };

function setup() {
  const hub = new FakeChannelHub();
  const initiator = new FakeWindow(ORIGIN);
  const callback = new FakeWindow(ORIGIN);
  return { hub, initiator, callback };
}

describe('MCP OAuth callback handoff', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('protocol constants are the agreement between both sides and must not change casually', () => {
    expect(MCP_OAUTH_CALLBACK_CHANNEL).toBe('oriveo:mcp-oauth-callback');
    expect(MCP_OAUTH_CALLBACK_MESSAGE_TYPE).toBe('oriveo:mcp-oauth-callback');
    expect(MCP_OAUTH_CALLBACK_ACK_TYPE).toBe('oriveo:mcp-oauth-callback-ack');
    expect(MCP_OAUTH_CALLBACK_ACK_TIMEOUT_MS).toBe(1500);
  });

  it('BroadcastChannel: a listener claims it, so it is handed back even without an opener (the production shape where COOP severs opener)', async () => {
    const { hub, initiator, callback } = setup();
    const onResult = vi.fn();
    listenForMcpOauthCallback({ state: 'state-A', origin: ORIGIN, messageTarget: initiator, onResult, openChannel: hub.open });

    const outcome = await deliverCallbackResult({
      params: PARAMS,
      origin: ORIGIN,
      opener: null,
      messageTarget: callback,
      openChannel: hub.open,
    });

    expect(outcome).toBe('claimed');
    expect(onResult).toHaveBeenCalledTimes(1);
    expect(onResult).toHaveBeenCalledWith(PARAMS);
    // Both sides cleaned up: channel closed, window listeners removed.
    expect(hub.channels.size).toBe(0);
    expect(initiator.listenerCount).toBe(0);
    expect(callback.listenerCount).toBe(0);
  });

  it('shape of the broadcast message and of the acknowledgement', async () => {
    const { hub, initiator, callback } = setup();
    const spy = hub.open();
    const seen: unknown[] = [];
    spy.addEventListener('message', (event) => seen.push(event.data));
    listenForMcpOauthCallback({ state: 'state-A', origin: ORIGIN, messageTarget: initiator, onResult: () => {}, openChannel: hub.open });

    await deliverCallbackResult({ params: PARAMS, origin: ORIGIN, opener: null, messageTarget: callback, openChannel: hub.open });
    await Promise.resolve();

    expect(seen).toEqual([
      { type: 'oriveo:mcp-oauth-callback', params: PARAMS },
      { type: 'oriveo:mcp-oauth-callback-ack', state: 'state-A' },
    ]);
  });

  it('no listener: unclaimed after the timeout (the tab that started the authorization is gone)', async () => {
    vi.useFakeTimers();
    const { hub, callback } = setup();
    let outcome: string | undefined;
    void deliverCallbackResult({ params: PARAMS, origin: ORIGIN, opener: null, messageTarget: callback, openChannel: hub.open })
      .then((value) => {
        outcome = value;
      });

    await vi.advanceTimersByTimeAsync(MCP_OAUTH_CALLBACK_ACK_TIMEOUT_MS - 1);
    expect(outcome).toBeUndefined();
    await vi.advanceTimersByTimeAsync(1);
    expect(outcome).toBe('unclaimed');
    expect(hub.channels.size).toBe(0);
    expect(callback.listenerCount).toBe(0);
    expect(vi.getTimerCount()).toBe(0);
  });

  it('state mismatch: neither claimed nor acknowledged; another flow waiting at the same time claims only its own', async () => {
    vi.useFakeTimers();
    const { hub, initiator, callback } = setup();
    const otherTab = new FakeWindow(ORIGIN);
    const onOther = vi.fn();
    const onMine = vi.fn();
    listenForMcpOauthCallback({ state: 'state-B', origin: ORIGIN, messageTarget: otherTab, onResult: onOther, openChannel: hub.open });

    let outcome: string | undefined;
    void deliverCallbackResult({ params: PARAMS, origin: ORIGIN, opener: null, messageTarget: callback, openChannel: hub.open })
      .then((value) => {
        outcome = value;
      });
    await vi.advanceTimersByTimeAsync(MCP_OAUTH_CALLBACK_ACK_TIMEOUT_MS);
    expect(outcome).toBe('unclaimed');
    expect(onOther).not.toHaveBeenCalled();
    // The state-B listener was not used up by this unrelated message and is still waiting.
    expect(hub.channels.size).toBe(1);

    // Two flows waiting at once: only the one whose state matches claims.
    listenForMcpOauthCallback({ state: 'state-A', origin: ORIGIN, messageTarget: initiator, onResult: onMine, openChannel: hub.open });
    const second = deliverCallbackResult({ params: PARAMS, origin: ORIGIN, opener: null, messageTarget: callback, openChannel: hub.open });
    await vi.advanceTimersByTimeAsync(0);
    await expect(second).resolves.toBe('claimed');
    expect(onMine).toHaveBeenCalledTimes(1);
    expect(onOther).not.toHaveBeenCalled();
  });

  it('an acknowledgement with a mismatching state is not treated as claimed by the callback page', async () => {
    vi.useFakeTimers();
    const { hub, callback } = setup();
    const impostor = hub.open();
    impostor.addEventListener('message', () => {
      impostor.postMessage({ type: MCP_OAUTH_CALLBACK_ACK_TYPE, state: 'some-other-state' });
      impostor.postMessage({ type: 'something-else', state: 'state-A' });
    });
    let outcome: string | undefined;
    void deliverCallbackResult({ params: PARAMS, origin: ORIGIN, opener: null, messageTarget: callback, openChannel: hub.open })
      .then((value) => {
        outcome = value;
      });
    await vi.advanceTimersByTimeAsync(MCP_OAUTH_CALLBACK_ACK_TIMEOUT_MS);
    expect(outcome).toBe('unclaimed');
  });

  it('opener channel fallback: without BroadcastChannel the result goes back through window.opener and the ack is received', async () => {
    const { initiator, callback } = setup();
    const onResult = vi.fn();
    listenForMcpOauthCallback({ state: 'state-A', origin: ORIGIN, messageTarget: initiator, onResult, openChannel: () => null });

    const outcome = await deliverCallbackResult({
      params: PARAMS,
      origin: ORIGIN,
      opener: initiator.asSeenBy(callback),
      messageTarget: callback,
      openChannel: () => null,
    });

    expect(outcome).toBe('claimed');
    expect(onResult).toHaveBeenCalledWith(PARAMS);
    // targetOrigin is fixed to this site's origin in both directions, never *.
    expect(initiator.received).toEqual([
      { data: { type: 'oriveo:mcp-oauth-callback', params: PARAMS }, targetOrigin: ORIGIN },
    ]);
    expect(callback.received).toEqual([
      { data: { type: 'oriveo:mcp-oauth-callback-ack', state: 'state-A' }, targetOrigin: ORIGIN },
    ]);
  });

  it('opener channel: same-shaped messages and acks from another origin are both ignored', async () => {
    vi.useFakeTimers();
    const { initiator, callback } = setup();
    const evil = new FakeWindow('https://evil.example.com');
    const onResult = vi.fn();
    listenForMcpOauthCallback({ state: 'state-A', origin: ORIGIN, messageTarget: initiator, onResult, openChannel: () => null });

    // A cross-origin page forges a callback result: the starting page does not claim it.
    const forgedInitiator = new FakeWindow('https://evil.example.com');
    const listeners: Array<(event: MessageEvent) => void> = [];
    const target = {
      addEventListener: (_type: 'message', listener: (event: MessageEvent) => void) => listeners.push(listener),
      removeEventListener: () => {},
    };
    const forgedResult = vi.fn();
    listenForMcpOauthCallback({ state: 'state-A', origin: ORIGIN, messageTarget: target, onResult: forgedResult, openChannel: () => null });
    for (const listener of listeners) {
      listener({
        data: { type: MCP_OAUTH_CALLBACK_MESSAGE_TYPE, params: { code: 'attacker-code', state: 'state-A' } },
        origin: 'https://evil.example.com',
        source: forgedInitiator.asSeenBy(evil),
      } as unknown as MessageEvent);
    }
    expect(forgedResult).not.toHaveBeenCalled();

    // A cross-origin page forges an ack: the callback page does not treat it as claimed.
    let outcome: string | undefined;
    void deliverCallbackResult({ params: PARAMS, origin: ORIGIN, opener: null, messageTarget: callback, openChannel: () => null })
      .then((value) => {
        outcome = value;
      });
    callback.asSeenBy(evil).postMessage({ type: MCP_OAUTH_CALLBACK_ACK_TYPE, state: 'state-A' }, ORIGIN);
    await vi.advanceTimersByTimeAsync(MCP_OAUTH_CALLBACK_ACK_TIMEOUT_MS);
    expect(outcome).toBe('unclaimed');
    expect(onResult).not.toHaveBeenCalled();
  });

  it('with both channels working the result is claimed only once', async () => {
    const { hub, initiator, callback } = setup();
    const onResult = vi.fn();
    listenForMcpOauthCallback({ state: 'state-A', origin: ORIGIN, messageTarget: initiator, onResult, openChannel: hub.open });

    const outcome = await deliverCallbackResult({
      params: PARAMS,
      origin: ORIGIN,
      opener: initiator.asSeenBy(callback),
      messageTarget: callback,
      openChannel: hub.open,
    });
    await Promise.resolve();
    await Promise.resolve();

    expect(outcome).toBe('claimed');
    expect(onResult).toHaveBeenCalledTimes(1);
  });

  it('a closed opener gets no delivery; a throwing opener access (cross-origin) is treated as no opener', async () => {
    vi.useFakeTimers();
    const { initiator, callback } = setup();
    initiator.closed = true;
    const closedOpener = initiator.asSeenBy(callback);
    const throwing = {
      get closed(): boolean {
        throw new Error('SecurityError');
      },
    } as unknown as Window;

    for (const opener of [closedOpener, throwing]) {
      let outcome: string | undefined;
      void deliverCallbackResult({ params: PARAMS, origin: ORIGIN, opener, messageTarget: callback, openChannel: () => null })
        .then((value) => {
          outcome = value;
        });
      await vi.advanceTimersByTimeAsync(MCP_OAUTH_CALLBACK_ACK_TIMEOUT_MS);
      expect(outcome).toBe('unclaimed');
    }
    expect(initiator.received).toEqual([]);
  });

  it('no state on the callback address: nobody can claim it, so it is unclaimed right away and the authorization code is not broadcast', async () => {
    const { hub, callback } = setup();
    const spy = hub.open();
    const seen: unknown[] = [];
    spy.addEventListener('message', (event) => seen.push(event.data));
    const opener = new FakeWindow(ORIGIN);

    await expect(
      deliverCallbackResult({
        params: { code: 'orphan-code' },
        origin: ORIGIN,
        opener: opener.asSeenBy(callback),
        messageTarget: callback,
        openChannel: hub.open,
      }),
    ).resolves.toBe('unclaimed');
    await Promise.resolve();
    expect(seen).toEqual([]);
    expect(opener.received).toEqual([]);
  });

  it('no claim after listening stops (authorization cancelled / page unloaded)', async () => {
    vi.useFakeTimers();
    const { hub, initiator, callback } = setup();
    const onResult = vi.fn();
    const stop = listenForMcpOauthCallback({ state: 'state-A', origin: ORIGIN, messageTarget: initiator, onResult, openChannel: hub.open });
    stop();
    stop();
    expect(hub.channels.size).toBe(0);
    expect(initiator.listenerCount).toBe(0);

    let outcome: string | undefined;
    void deliverCallbackResult({
      params: PARAMS,
      origin: ORIGIN,
      opener: initiator.asSeenBy(callback),
      messageTarget: callback,
      openChannel: hub.open,
    }).then((value) => {
      outcome = value;
    });
    await vi.advanceTimersByTimeAsync(MCP_OAUTH_CALLBACK_ACK_TIMEOUT_MS);
    expect(outcome).toBe('unclaimed');
    expect(onResult).not.toHaveBeenCalled();
  });

  it('malformed broadcasts are ignored', async () => {
    const { hub, initiator } = setup();
    const onResult = vi.fn();
    listenForMcpOauthCallback({ state: 'state-A', origin: ORIGIN, messageTarget: initiator, onResult, openChannel: hub.open });
    const sender = hub.open();
    for (const message of [
      null,
      'state-A',
      { type: MCP_OAUTH_CALLBACK_MESSAGE_TYPE },
      { type: MCP_OAUTH_CALLBACK_MESSAGE_TYPE, params: null },
      { type: MCP_OAUTH_CALLBACK_MESSAGE_TYPE, params: ['state-A'] },
      { type: MCP_OAUTH_CALLBACK_MESSAGE_TYPE, params: { state: 'state-A', code: 42 } },
      { type: 'other', params: { state: 'state-A' } },
      { type: MCP_OAUTH_CALLBACK_ACK_TYPE, state: 'state-A' },
    ]) {
      sender.postMessage(message);
    }
    await Promise.resolve();
    await Promise.resolve();
    expect(onResult).not.toHaveBeenCalled();
  });

  it('collectCallbackParams collects every query parameter as is', () => {
    expect(collectCallbackParams('?code=a%20b&state=xyz&iss=https%3A%2F%2Fauth.example.com')).toEqual({
      code: 'a b',
      state: 'xyz',
      iss: 'https://auth.example.com',
    });
    expect(collectCallbackParams('?error=access_denied&error_description=nope&state=s')).toEqual({
      error: 'access_denied',
      error_description: 'nope',
      state: 's',
    });
    expect(collectCallbackParams('')).toEqual({});
  });

  it('scrubCallbackUrl removes the query string and fragment from the address bar and keeps history.state', () => {
    const state = { __NA: true };
    const replaceState = vi.fn();
    scrubCallbackUrl({
      history: { state, replaceState } as unknown as History,
      location: { pathname: '/mcp/oauth/callback', search: '?code=abc&state=xyz', hash: '#frag' } as Location,
    });
    expect(replaceState).toHaveBeenCalledTimes(1);
    expect(replaceState).toHaveBeenCalledWith(state, '', '/mcp/oauth/callback');

    // History is left alone when the address bar is already clean.
    replaceState.mockClear();
    scrubCallbackUrl({
      history: { state, replaceState } as unknown as History,
      location: { pathname: '/mcp/oauth/callback', search: '', hash: '' } as Location,
    });
    expect(replaceState).not.toHaveBeenCalled();
  });
});
