/**
 * The three browser-side injection points of the remote MCP core (`@oriveo/core/mcp`): transport,
 * randomness and the authorization page.
 *
 * - Transport: public servers go through this site's `/api/mcp/forward`; private-network, LAN and
 *   non-allowlisted-port servers are reached directly from the browser. The decision reuses the
 *   relay's `shouldProxyRelayViaServer`, the same private-network check as the server-side SSRF
 *   guard, which rules out the dead end of "judged public -> forwarded -> rejected by SSRF".
 * - Authorization page: the authorization URL opens in a new window and the callback page hands the
 *   query parameters back over a same-origin BroadcastChannel. The opener side only uses
 *   `listenForMcpOauthCallback` and never builds messages itself.
 */

import {
  createDirectMcpTransport,
  createForwardMcpTransport,
  createRoutingMcpTransport,
  mcpWebClientIdentity,
  type McpAuthorizationLauncher,
  type McpClientIdentity,
  type McpExclusiveLock,
  type McpFetch,
  type McpRandomPort,
  type McpTransport,
} from '@oriveo/core/mcp/index';
import { listenForMcpOauthCallback, type OauthCallbackChannel, type OauthCallbackMessageTarget } from '../../../app/mcp/oauth/callback/callback-handoff';
import { shouldProxyRelayViaServer } from '../providers/relay-browser-direct';
import { registerMcpDirectRequestURL } from '../../sentry/redact-url';

/** Narrows `window.fetch` to the shape the core expects (with `redirect: 'manual'` the direct transport follows redirects itself). */
export function browserMcpFetch(fetchImpl: typeof fetch = (...args) => fetch(...args)): McpFetch {
  return async (url, init) => {
    const response = await fetchImpl(url, {
      method: init.method,
      headers: init.headers,
      body: init.body,
      signal: init.signal,
      redirect: init.redirect,
      // MCP requests authenticate only through headers we set ourselves: never send this site's
      // cookies out, and never let a third party set any.
      credentials: 'omit',
      cache: 'no-store',
    });
    return { status: response.status, type: response.type, headers: response.headers, body: response.body };
  };
}

export function createBrowserMcpTransport(options: { fetch?: McpFetch } = {}): McpTransport {
  const fetchPort = options.fetch ?? browserMcpFetch();
  return createRoutingMcpTransport({
    shouldForward: shouldProxyRelayViaServer,
    forward: createForwardMcpTransport({ fetch: fetchPort }),
    direct: createDirectMcpTransport(async (url, init) => {
      // A directly reached URL ends up in Sentry's fetch breadcrumbs and spans (the forwarded path
      // only ever shows `/api/mcp/forward`). Register its origin before sending so it is masked in
      // full before reporting, since the URL itself may carry a secret.
      registerMcpDirectRequestURL(url);
      return fetchPort(url, init);
    }),
  });
}

/**
 * This page's identity towards the authorization server: the redirect URI and the CIMD `client_id`
 * are always derived from the **current origin**. When the current origin is not public https
 * (localhost, a private network, a LAN hostname) the authorization server cannot fetch our CIMD
 * document, so CIMD is skipped and only DCR is used. The public check is the same one as the SSRF
 * guard of the forward route (`shouldProxyRelayViaServer`).
 */
export function browserMcpClientIdentity(origin: string = window.location.origin): McpClientIdentity {
  return mcpWebClientIdentity(origin, { publiclyReachable: origin.startsWith('https://') && shouldProxyRelayViaServer(origin) });
}

/**
 * Cross-tab mutual exclusion for token refresh: concurrent refreshes for the same server must be
 * serialized. Once a refresh token is rotated the old one is void immediately, so when two tabs
 * each present the same old token the later one gets `invalid_grant`. Without `navigator.locks`
 * this falls back to the authorizer's own in-process serialization.
 */
export const browserMcpRefreshLock: McpExclusiveLock = (name, task) => {
  const locks = typeof navigator !== 'undefined' ? (navigator as Navigator & { locks?: LockManager }).locks : undefined;
  if (!locks?.request) return task();
  return locks.request(name, { mode: 'exclusive' }, task) as ReturnType<typeof task>;
};

export const browserMcpRandom: McpRandomPort = {
  randomBytes(count) {
    return globalThis.crypto.getRandomValues(new Uint8Array(count));
  },
};

/** After the authorization window closes, how long to keep waiting for the callback page's broadcast before treating it as cancelled by the user. */
const CLOSED_GRACE_MS = 3_000;
const CLOSED_POLL_MS = 500;
/** Overall time limit for one browser sign-in, so the opener page does not hang forever when the user wanders off. */
const AUTHORIZATION_TIMEOUT_MS = 10 * 60_000;

export class McpAuthorizationWindowError extends Error {
  readonly reason: 'blocked' | 'closed' | 'timeout' | 'aborted';
  constructor(reason: 'blocked' | 'closed' | 'timeout' | 'aborted') {
    super(`MCP authorization window ${reason}`);
    this.name = 'McpAuthorizationWindowError';
    this.reason = reason;
  }
}

export interface BrowserAuthorizationLauncherOptions {
  openWindow?: (url: string) => Pick<Window, 'closed' | 'close'> | null;
  messageTarget?: OauthCallbackMessageTarget;
  origin?: string;
  openChannel?: () => OauthCallbackChannel | null;
  closedGraceMs?: number;
  timeoutMs?: number;
}

/**
 * Authorization in a new window. The window must open synchronously inside a user gesture (or the
 * popup blocker stops it), so the caller reaches this straight from the click handler of the
 * "continue to sign in" button without awaiting anything in between.
 *
 * Deciding that "the user closed the window" needs some slack: the site-wide COOP moves the
 * callback page into a different browsing context group, so the window handle held by the opener
 * may already report `closed` while the callback page's broadcast is still on its way.
 */
export function createBrowserMcpAuthorizationLauncher(options: BrowserAuthorizationLauncherOptions = {}): McpAuthorizationLauncher {
  return {
    open(request) {
      const openWindow = options.openWindow ?? ((url: string) => window.open(url, 'oriveo-mcp-oauth', 'popup,width=520,height=720'));
      const messageTarget = options.messageTarget ?? window;
      const origin = options.origin ?? window.location.origin;
      const graceMs = options.closedGraceMs ?? CLOSED_GRACE_MS;

      return new Promise((resolve, reject) => {
        if (request.signal?.aborted) {
          reject(new McpAuthorizationWindowError('aborted'));
          return;
        }
        let settled = false;
        let closedAt: number | null = null;
        const popup = openWindow(request.url);
        const finish = (outcome: { params: Record<string, string> } | McpAuthorizationWindowError) => {
          if (settled) return;
          settled = true;
          stopListening();
          clearInterval(poll);
          clearTimeout(deadline);
          request.signal?.removeEventListener('abort', onAbort);
          if (outcome instanceof McpAuthorizationWindowError) {
            try {
              popup?.close();
            } catch {
              // Already closed.
            }
            reject(outcome);
          } else {
            resolve(outcome);
          }
        };
        const stopListening = listenForMcpOauthCallback({
          state: request.state,
          origin,
          messageTarget,
          openChannel: options.openChannel,
          onResult: (params) => finish({ params }),
        });
        const onAbort = () => finish(new McpAuthorizationWindowError('aborted'));
        request.signal?.addEventListener('abort', onAbort, { once: true });
        const deadline = setTimeout(() => finish(new McpAuthorizationWindowError('timeout')), options.timeoutMs ?? AUTHORIZATION_TIMEOUT_MS);
        const poll = setInterval(() => {
          if (!popup) return;
          let closed = false;
          try {
            closed = popup.closed;
          } catch {
            closed = false;
          }
          if (!closed) {
            closedAt = null;
            return;
          }
          closedAt ??= Date.now();
          if (Date.now() - closedAt >= graceMs) finish(new McpAuthorizationWindowError('closed'));
        }, CLOSED_POLL_MS);
        if (!popup) finish(new McpAuthorizationWindowError('blocked'));
      });
    },
  };
}

/**
 * "Open first, navigate later" for the authorization window. After the user presses "continue" the
 * authorizer still has to register the client (a network request) before it has the authorization
 * URL, and calling `window.open` at that point is outside the user gesture and gets blocked. So a
 * blank window is opened **synchronously** in the click handler (`preopen`), and once the
 * authorization URL is known that window is simply navigated to it.
 */
export interface McpPreopenedAuthorization {
  /** Call synchronously in the click handler. Returns false when the browser blocked it (the sign-in then ends as not completed). */
  preopen(): boolean;
  launcher: McpAuthorizationLauncher;
  /** Closes the blank window when the flow ends before reaching the authorization page. */
  discard(): void;
}

export function createPreopenedMcpAuthorization(
  options: Omit<BrowserAuthorizationLauncherOptions, 'openWindow'> & { openBlank?: () => Window | null } = {},
): McpPreopenedAuthorization {
  let popup: Window | null = null;
  let handedOver = false;
  const { openBlank, ...launcherOptions } = options;
  return {
    preopen() {
      handedOver = false;
      popup = (openBlank ?? (() => window.open('', 'oriveo-mcp-oauth', 'popup,width=520,height=720')))();
      return popup !== null;
    },
    launcher: createBrowserMcpAuthorizationLauncher({
      ...launcherOptions,
      openWindow: (url) => {
        const target = popup;
        if (!target) return null;
        handedOver = true;
        try {
          target.location.href = url;
        } catch {
          return null;
        }
        return target;
      },
    }),
    discard() {
      if (popup && !handedOver) {
        try {
          popup.close();
        } catch {
          // Already closed.
        }
      }
      popup = null;
    },
  };
}
