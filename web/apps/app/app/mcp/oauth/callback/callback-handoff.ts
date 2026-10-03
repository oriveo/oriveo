/**
 * The handoff between the MCP OAuth callback page and the page that started the authorization.
 *
 * The starting page opens the authorization page with `window.open`. When authorization completes,
 * the authorization server redirects to the callback address `<origin>/mcp/oauth/callback`, and the
 * result has to be handed back to the starting page.
 *
 * ## Why the primary channel is BroadcastChannel rather than window.opener
 *
 * Every path on this site sends `Cross-Origin-Opener-Policy: same-origin-allow-popups`
 * (next.config.ts). The popup first visits the authorization server's page (cross-origin, without
 * that header) and then returns to the callback page, which has it. The COOP of the two navigations
 * does not match, so the browser puts the callback page in a new browsing context group and
 * `window.opener` becomes null. Relying on opener, the result would never reach the starting page.
 *
 * BroadcastChannel only looks at the origin, not at which window opened which, so COOP does not
 * affect it. `opener.postMessage` is kept as a second channel (deployments without COOP, older
 * browsers without BroadcastChannel).
 *
 * ## Protocol
 *
 * 1. The callback page broadcasts `{ type, params }` on the channel, where `params` is every query
 *    parameter on the callback address.
 * 2. The starting page claims only a message whose `params.state` equals the `state` of its own
 *    authorization, and replies `{ type: ack, state }`. Other tabs and other authorization flows
 *    receiving the same broadcast see a `state` that does not match, so they neither claim nor
 *    acknowledge it.
 * 3. If the callback page receives the acknowledgement within the time limit it shows "done" and
 *    tries to close itself. If not, no open page is waiting for this authorization (the tab that
 *    started it was closed or reloaded), and it shows "please return to the app".
 *
 * A broadcast can be received by any same-origin page, which is the same trust boundary as what the
 * starting page can read anyway. The authorization code alone cannot be exchanged for a token: the
 * PKCE code verifier is held only by the starting page.
 */

/** The BroadcastChannel name. The starting page and the callback page must use the same one. */
export const MCP_OAUTH_CALLBACK_CHANNEL = 'oriveo:mcp-oauth-callback';
export const MCP_OAUTH_CALLBACK_MESSAGE_TYPE = 'oriveo:mcp-oauth-callback';
export const MCP_OAUTH_CALLBACK_ACK_TYPE = 'oriveo:mcp-oauth-callback-ack';
/**
 * How long the callback page waits for the acknowledgement. Messages between same-origin pages take
 * milliseconds, so 1.5 seconds is enough to tell "someone claimed it" from "nobody did".
 */
export const MCP_OAUTH_CALLBACK_ACK_TIMEOUT_MS = 1500;

export interface McpOauthCallbackMessage {
  type: typeof MCP_OAUTH_CALLBACK_MESSAGE_TYPE;
  /**
   * Every query parameter on the callback URL (code / state / iss / error …), passed on as is and not
   * interpreted at this layer.
   */
  params: Record<string, string>;
}

export interface McpOauthCallbackAck {
  type: typeof MCP_OAUTH_CALLBACK_ACK_TYPE;
  /** The state of the claimed authorization. The callback page uses it to confirm the ack is its own. */
  state: string;
}

/** The subset of BroadcastChannel both sides actually use; tests inject a double of the same shape. */
export interface OauthCallbackChannel {
  postMessage(message: unknown): void;
  addEventListener(type: 'message', listener: (event: MessageEvent) => void): void;
  removeEventListener(type: 'message', listener: (event: MessageEvent) => void): void;
  close(): void;
}

/** The subset of window both sides actually use (the opener channel). */
export interface OauthCallbackMessageTarget {
  addEventListener(type: 'message', listener: (event: MessageEvent) => void): void;
  removeEventListener(type: 'message', listener: (event: MessageEvent) => void): void;
}

export type OauthCallbackDelivery = 'claimed' | 'unclaimed';

export function collectCallbackParams(search: string): Record<string, string> {
  const params: Record<string, string> = {};
  for (const [key, value] of new URLSearchParams(search)) {
    params[key] = value;
  }
  return params;
}

/**
 * Returns null when the browser does not support it or policy disables it (some private modes throw
 * a SecurityError).
 */
export function openOauthCallbackChannel(): OauthCallbackChannel | null {
  if (typeof BroadcastChannel !== 'function') return null;
  try {
    return new BroadcastChannel(MCP_OAUTH_CALLBACK_CHANNEL);
  } catch {
    return null;
  }
}

function isRecordOfStrings(value: unknown): value is Record<string, string> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false;
  return Object.values(value).every((entry) => typeof entry === 'string');
}

function isCallbackMessage(data: unknown): data is McpOauthCallbackMessage {
  if (typeof data !== 'object' || data === null) return false;
  const candidate = data as { type?: unknown; params?: unknown };
  return candidate.type === MCP_OAUTH_CALLBACK_MESSAGE_TYPE && isRecordOfStrings(candidate.params);
}

function isAckFor(data: unknown, state: string): boolean {
  if (typeof data !== 'object' || data === null) return false;
  const candidate = data as { type?: unknown; state?: unknown };
  return candidate.type === MCP_OAUTH_CALLBACK_ACK_TYPE && candidate.state === state;
}

/**
 * The second channel for handing the result to the starting window. Returns false when there is no
 * opener (or it is closed). `targetOrigin` must be this site's origin, not `*`: the callback page
 * and the starting window are same-origin, so there is no reason to loosen it.
 */
export function handBackToOpener(
  opener: Window | null,
  params: Record<string, string>,
  targetOrigin: string,
): boolean {
  if (!opener || opener.closed) return false;
  const message: McpOauthCallbackMessage = { type: MCP_OAUTH_CALLBACK_MESSAGE_TYPE, params };
  opener.postMessage(message, targetOrigin);
  return true;
}

export interface DeliverCallbackResultInput {
  params: Record<string, string>;
  /** This site's origin: the targetOrigin of the opener channel and the expected source of the ack. */
  origin: string;
  opener: Window | null;
  /** This window, used to receive the ack on the opener channel. */
  messageTarget: OauthCallbackMessageTarget;
  openChannel?: () => OauthCallbackChannel | null;
  timeoutMs?: number;
}

/**
 * Callback page side: sends the result on both channels and waits for the starting page to claim it.
 *
 * Both channels are used at once rather than one after the other: the starting page claims only once
 * per `state` (see listenForMcpOauthCallback), so a duplicate delivery is harmless, whereas going
 * sequentially would make the opener channel wait out a whole timeout for nothing.
 *
 * A callback without `state` cannot be claimed by anyone (the starting page claims by state only),
 * so it is `unclaimed` right away and nothing is broadcast.
 */
export function deliverCallbackResult(input: DeliverCallbackResultInput): Promise<OauthCallbackDelivery> {
  const state = input.params.state;
  if (!state) return Promise.resolve('unclaimed');

  const channel = (input.openChannel ?? openOauthCallbackChannel)();
  const message: McpOauthCallbackMessage = { type: MCP_OAUTH_CALLBACK_MESSAGE_TYPE, params: input.params };

  return new Promise<OauthCallbackDelivery>((resolve) => {
    let settled = false;
    const finish = (outcome: OauthCallbackDelivery) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      channel?.removeEventListener('message', onChannelMessage);
      channel?.close();
      input.messageTarget.removeEventListener('message', onWindowMessage);
      resolve(outcome);
    };
    const onChannelMessage = (event: MessageEvent) => {
      if (isAckFor(event.data, state)) finish('claimed');
    };
    const onWindowMessage = (event: MessageEvent) => {
      // Ack on the opener channel: accepted only from this site's origin.
      if (event.origin !== input.origin) return;
      if (isAckFor(event.data, state)) finish('claimed');
    };
    const timer = setTimeout(() => finish('unclaimed'), input.timeoutMs ?? MCP_OAUTH_CALLBACK_ACK_TIMEOUT_MS);

    channel?.addEventListener('message', onChannelMessage);
    input.messageTarget.addEventListener('message', onWindowMessage);

    try {
      channel?.postMessage(message);
    } catch {
      // Edge cases such as the channel being closed elsewhere: the opener channel and the timeout
      // still cover it.
    }
    try {
      handBackToOpener(input.opener, input.params, input.origin);
    } catch {
      // A cross-origin or stale opener throws; treat it as having no opener.
    }
  });
}

export interface ListenForMcpOauthCallbackInput {
  /** The state sent in this authorization request. Only a result coming back with it is claimed. */
  state: string;
  /**
   * This site's origin: the expected source of messages on the opener channel and the targetOrigin
   * of the ack.
   */
  origin: string;
  /** The window the starting page lives in, used to receive messages on the opener channel. */
  messageTarget: OauthCallbackMessageTarget;
  /**
   * Called at most once, when a result is claimed. `params` is every query parameter on the callback
   * address.
   */
  onResult: (params: Record<string, string>) => void;
  openChannel?: () => OauthCallbackChannel | null;
}

/**
 * Starting page side: begins waiting for the callback page to hand the result back, and returns a
 * function that stops listening (call it when authorization is cancelled or the page unloads).
 *
 * - Only a message with `params.state === state` is claimed; a mismatch is neither claimed nor
 *   acknowledged, because it belongs to another tab's or another server's authorization flow, each
 *   of which has its own listener.
 * - A claim is acknowledged immediately, then `onResult` is called and listening stops. When the
 *   same result arrives once on each channel, only the first is claimed.
 * - This is the handoff only. Validation beyond `state` (`iss`, error, the token exchange) is the
 *   caller's job.
 */
export function listenForMcpOauthCallback(input: ListenForMcpOauthCallbackInput): () => void {
  const channel = (input.openChannel ?? openOauthCallbackChannel)();
  let stopped = false;

  const stop = () => {
    if (stopped) return;
    stopped = true;
    channel?.removeEventListener('message', onChannelMessage);
    channel?.close();
    input.messageTarget.removeEventListener('message', onWindowMessage);
  };

  const claim = (data: unknown, acknowledge: (ack: McpOauthCallbackAck) => void) => {
    if (stopped) return;
    if (!isCallbackMessage(data)) return;
    if (data.params.state !== input.state) return;
    try {
      acknowledge({ type: MCP_OAUTH_CALLBACK_ACK_TYPE, state: input.state });
    } catch {
      // A failed ack does not affect the claim: the result is already in hand, and at worst the
      // callback page shows an extra "please return to the app".
    }
    stop();
    input.onResult(data.params);
  };

  const onChannelMessage = (event: MessageEvent) => {
    claim(event.data, (ack) => channel?.postMessage(ack));
  };
  const onWindowMessage = (event: MessageEvent) => {
    if (event.origin !== input.origin) return;
    claim(event.data, (ack) => {
      (event.source as Window | null)?.postMessage(ack, input.origin);
    });
  };

  channel?.addEventListener('message', onChannelMessage);
  input.messageTarget.addEventListener('message', onWindowMessage);
  return stop;
}

/**
 * Removes the authorization code and other parameters from the address bar (they have already been
 * read into memory). Left there, they would enter browser history, be carried off as the page
 * address by any later reporting, and a refresh would submit an already used authorization code
 * again. history.state is kept: the Next router stores its own state in it.
 */
export function scrubCallbackUrl(target: Pick<Window, 'history' | 'location'>): void {
  if (!target.location.search && !target.location.hash) return;
  target.history.replaceState(target.history.state, '', target.location.pathname);
}
