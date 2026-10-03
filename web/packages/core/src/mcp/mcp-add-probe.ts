/**
 * Connection probe state machine for adding a server, plus the coordination that saves the result.
 *
 * Validate the URL -> connect once without credentials -> (success / not MCP / unreachable / sign-in
 * required). When sign-in is required the flow branches on `authKind`: `token` retries with the token,
 * `auto` runs authorization discovery (CIMD / DCR / neither supported).
 *
 * **A server record is saved only after its tool list has been read; no failure leaves half a server
 * behind** - record, tool snapshot, default permissions, connection state and credentials. A successful
 * browser sign-in has already put the token into the credential store, so any later failure (reading the
 * tool list, hitting the limit, a failed save, cancellation) must delete it.
 *
 * The production entry point is `McpAddCoordinator.add` (probe + save + exactly one terminal state).
 * `McpAddProbe` only probes and never saves.
 */

import type { McpAuthorizationLauncher, McpAuthorizer } from './mcp-auth';
import { McpAuthorizerError } from './mcp-auth';
import { buildToolSnapshots, defaultToolPermissions } from './mcp-catalog';
import { McpClient, McpClientError, type McpSession } from './mcp-client';
import type { McpCredentialStore } from './mcp-credentials';
import type { McpTransport } from './mcp-transport';
import {
  MCP_RUNTIME_CONFIG_FALLBACK,
  MCP_SERVER_MAX_NAME_LENGTH,
  MCP_SERVER_MAX_URL_LENGTH,
  type McpAuthKind,
  type McpConnectionState,
  type McpRuntimeConfig,
  type McpServerRecord,
  type McpToolPermission,
  type McpToolSnapshot,
} from './mcp-types';

/** Why URL validation failed. Both lead to the same "invalid URL" step (23); only the explanatory text differs. */
export type McpInvalidUrlReason =
  /** Incomplete, not `https://`, or too long. */
  | 'malformed'
  /** The URL carries a username or password: the explanation tells the user to use an access token instead. */
  | 'hasUserinfo';

/**
 * Validates the URL (the first step of the add flow) and reports why it was rejected: only `https://`,
 * a host name, at most 2048 bytes, and no userinfo part (browser fetch forbids credentials inside a URL,
 * so every client rejects them at this step and suggests an access token instead).
 */
export function checkMcpEndpoint(raw: string): { ok: true; url: string } | { ok: false; reason: McpInvalidUrlReason } {
  const trimmed = raw.trim();
  if (!trimmed || new TextEncoder().encode(trimmed).length > MCP_SERVER_MAX_URL_LENGTH) return { ok: false, reason: 'malformed' };
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    return { ok: false, reason: 'malformed' };
  }
  // WHATWG URL already lowercases the scheme, so only lowercase `https://` gets through.
  if (url.protocol !== 'https:' || !url.hostname) return { ok: false, reason: 'malformed' };
  if (url.username || url.password) return { ok: false, reason: 'hasUserinfo' };
  url.hash = '';
  return { ok: true, url: url.toString() };
}

/** Returns the normalized URL, or `null` when validation fails (see `checkMcpEndpoint` for the reason). */
export function validateMcpEndpoint(raw: string): string | null {
  const checked = checkMcpEndpoint(raw);
  return checked.ok ? checked.url : null;
}

/** The result once the tool list has been read. */
export interface McpAddReview {
  serverId: string;
  session: McpSession;
  /** New or changed tools have `pendingReview = true` and are not sent out until the user confirms them. */
  tools: McpToolSnapshot[];
  /** Tools declared read-only default to `auto`, everything else to `ask`. */
  defaultPermissions: Record<string, McpToolPermission>;
}

/** Probe states: four progress states followed by the terminal ones. */
export type McpAddState =
  | { kind: 'connecting' }
  /** Pre-sign-in prompt: the state machine waits here for consent; until then no client is registered and no browser is opened. */
  | { kind: 'authPrompt'; authorizationHost: string }
  | { kind: 'browser' }
  | { kind: 'finishing' }
  | { kind: 'review'; review: McpAddReview }
  /** Invalid URL (including URLs that are not `https://` and URLs with a userinfo part). */
  | { kind: 'invalidURL'; reason: McpInvalidUrlReason }
  | { kind: 'unreachable' }
  | { kind: 'notMcp' }
  | { kind: 'needsToken' }
  | { kind: 'authCancelled' }
  /** "Token field error": with `authKind = token`, the retry carrying the token still demands sign-in. */
  | { kind: 'tokenRejected' }
  | { kind: 'limitReached'; max: number }
  /** The add was cancelled. No record or credential is left behind. */
  | { kind: 'cancelled' }
  /** Connected and read the tools, but writing local storage failed (or the serverId collides with an existing server). No record or credential is left behind. */
  | { kind: 'saveFailed' };

/** The first four states are progress states; everything else is terminal. */
export function isTerminalAddState(state: McpAddState): boolean {
  return !['connecting', 'authPrompt', 'browser', 'finishing'].includes(state.kind);
}

/** What the pre-sign-in prompt shows: the host of the authorization endpoint (the sign-in page the user will see in the browser). */
export interface McpAuthPrompt {
  authorizationHost: string;
  /** Which kind of client registration this sign-in will use (informational only, never displayed). */
  registrationKind: 'cimd' | 'dcr';
}

export type McpAddProgress = (state: McpAddState) => void | Promise<void>;
/** Pre-sign-in gate: shows the prompt and waits for the user's decision. Only `true` continues (register the client, open the browser). */
export type McpAuthorizationGate = (prompt: McpAuthPrompt) => Promise<boolean>;

export interface McpAddProbeOptions {
  runtimeConfig?: McpRuntimeConfig;
  authorizer: McpAuthorizer;
  /** Must be the same one `authorizer` uses: on failure the token stored by this sign-in is deleted from it. */
  credentialStore: McpCredentialStore;
  /** Production passes a transport; tests may pass `makeClient` instead. */
  transport?: McpTransport;
  makeClient?: (endpoint: string) => McpClient;
}

export interface McpProbeRequest {
  url: string;
  authKind: McpAuthKind;
  uid: string;
  /** The access token the user entered when `authKind = token`. */
  token?: string | null;
  /** Must be a server that does not exist yet: on failure the credentials under this id are deleted. */
  serverId: string;
  /** Omitting it means the user did not consent: no client is registered and no browser is opened. */
  confirmAuthorization?: McpAuthorizationGate;
  /** The authorization page for this add (each click opens its own window); defaults to the authorizer's. */
  launcher?: McpAuthorizationLauncher;
  progress?: McpAddProgress;
  signal?: AbortSignal;
}

/** Connection probe state machine. Does not write server storage. */
export class McpAddProbe {
  private readonly runtimeConfig: McpRuntimeConfig;
  private readonly authorizer: McpAuthorizer;
  private readonly credentialStore: McpCredentialStore;
  private readonly makeClient: (endpoint: string) => McpClient;

  constructor(options: McpAddProbeOptions) {
    this.runtimeConfig = options.runtimeConfig ?? MCP_RUNTIME_CONFIG_FALLBACK;
    this.authorizer = options.authorizer;
    this.credentialStore = options.credentialStore;
    const runtimeConfig = this.runtimeConfig;
    const transport = options.transport;
    this.makeClient =
      options.makeClient ??
      ((endpoint) => {
        if (!transport) throw new Error('McpAddProbe needs a transport or makeClient');
        return new McpClient({ endpoint, transport, runtimeConfig });
      });
  }

  /**
   * Runs the probe once and returns the terminal state. Progress states are reported through `progress`
   * in order; **the terminal state is not** - the caller emits it once after saving, so the UI never
   * sees "success" followed by "failure". Before any failed terminal state is returned, the credentials
   * stored by this sign-in have already been deleted.
   */
  async run(request: McpProbeRequest): Promise<McpAddState> {
    const checked = checkMcpEndpoint(request.url);
    if (!checked.ok) return { kind: 'invalidURL', reason: checked.reason };
    const endpoint = checked.url;
    const state = await this.explore(endpoint, request);
    if (state.kind !== 'review') await this.discardCredentials(request.serverId, request.uid);
    return state;
  }

  private async discardCredentials(serverId: string, uid: string): Promise<void> {
    try {
      await this.credentialStore.delete(serverId, uid);
    } catch {
      // The add has already failed; a failed delete must not mask the reason.
    }
  }

  private async explore(endpoint: string, request: McpProbeRequest): Promise<McpAddState> {
    const { signal } = request;
    if (signal?.aborted) return { kind: 'cancelled' };
    await request.progress?.({ kind: 'connecting' });

    const client = this.makeClient(endpoint);
    const first = await client.connect({ signal });
    switch (first.kind) {
      case 'connected':
        return this.finish(client, first.session, request);
      case 'notMcp':
        return { kind: 'notMcp' };
      case 'failed':
        return failureState(first.error, signal);
      case 'unreachable':
        return signal?.aborted ? { kind: 'cancelled' } : { kind: 'unreachable' };
      case 'needsAuth':
        break;
    }

    if (request.authKind === 'token') {
      if (!request.token) return { kind: 'tokenRejected' };
      return this.retryWithToken(client, request.token, request);
    }
    return this.runDiscovery(client, endpoint, request);
  }

  /** `authKind = auto`: can register automatically -> 19 (wait for consent) -> 20 -> sign in -> 21 / 22; cannot -> 26. */
  private async runDiscovery(client: McpClient, endpoint: string, request: McpProbeRequest): Promise<McpAddState> {
    const { signal } = request;
    const discovery = await this.authorizer.discover(client.authChallenge, endpoint);
    if (signal?.aborted) return { kind: 'cancelled' };
    // Metadata could not be fetched this time (network / timeout / 5xx): that is "unreachable", not a "needs an access token" conclusion.
    if (discovery.kind === 'temporarilyUnavailable') return { kind: 'unreachable' };
    if (discovery.kind === 'needsToken') return { kind: 'needsToken' };

    // Pre-sign-in gate: only GETs have been sent so far. DCR registration leaves a client on the
    // authorization server and opening the browser takes the user to a third-party page - both must
    // happen only after the user consents.
    const plan = discovery.plan;
    const authorizationHost = hostOf(plan.authorizationEndpoint) ?? plan.issuer;
    await request.progress?.({ kind: 'authPrompt', authorizationHost });
    const approved = request.confirmAuthorization
      ? await request.confirmAuthorization({ authorizationHost, registrationKind: plan.registrationKind })
      : false;
    if (signal?.aborted) return { kind: 'cancelled' };
    if (!approved) return { kind: 'authCancelled' };

    await request.progress?.({ kind: 'browser' });
    let token: string | null;
    try {
      const credentials = await this.authorizer.authorize(plan, request.serverId, request.uid, { signal, launcher: request.launcher });
      token = credentials.accessToken ?? credentials.pastedToken ?? null;
    } catch (error) {
      if (signal?.aborted) return { kind: 'cancelled' };
      if (error instanceof McpAuthorizerError && error.isTransient) return { kind: 'unreachable' };
      // User cancelled / provider refused / redirect rejected -> 27, sign-in not completed.
      return { kind: 'authCancelled' };
    }
    if (signal?.aborted) return { kind: 'cancelled' };
    if (!token) return { kind: 'authCancelled' };
    return this.retryWithToken(client, token, { ...request, authKind: 'auto' });
  }

  /** Reconnects with a token. If sign-in is still required: pasted token -> token field error; browser sign-in -> sign-in not completed. */
  private async retryWithToken(client: McpClient, token: string, request: McpProbeRequest): Promise<McpAddState> {
    const outcome = await client.connect({ bearerToken: token, signal: request.signal });
    switch (outcome.kind) {
      case 'connected':
        return this.finish(client, outcome.session, request);
      case 'needsAuth':
        return rejectedState(request.authKind);
      case 'notMcp':
        return { kind: 'notMcp' };
      case 'failed':
        return failureState(outcome.error, request.signal);
      case 'unreachable':
        return request.signal?.aborted ? { kind: 'cancelled' } : { kind: 'unreachable' };
    }
  }

  /** 21 read the tool list -> 22 confirm default permissions. */
  private async finish(client: McpClient, session: McpSession, request: McpProbeRequest): Promise<McpAddState> {
    if (request.signal?.aborted) return { kind: 'cancelled' };
    await request.progress?.({ kind: 'finishing' });
    try {
      const definitions = await client.listTools({ signal: request.signal });
      if (request.signal?.aborted) return { kind: 'cancelled' };
      const tools = buildToolSnapshots({ serverId: request.serverId, definitions, runtimeConfig: this.runtimeConfig });
      return { kind: 'review', review: { serverId: request.serverId, session, tools, defaultPermissions: defaultToolPermissions(tools) } };
    } catch (error) {
      if (error instanceof McpClientError) {
        if (error.code === 'needs_auth') return rejectedState(request.authKind);
        return failureState(error, request.signal);
      }
      return request.signal?.aborted ? { kind: 'cancelled' } : { kind: 'unreachable' };
    }
  }
}

function rejectedState(authKind: McpAuthKind): McpAddState {
  return authKind === 'token' ? { kind: 'tokenRejected' } : { kind: 'authCancelled' };
}

/** Cancellation has its own terminal state and is not folded into "unreachable"; timeouts and server errors still are "unreachable". */
function failureState(error: McpClientError, signal?: AbortSignal): McpAddState {
  return error.code === 'cancelled' || signal?.aborted ? { kind: 'cancelled' } : { kind: 'unreachable' };
}

function hostOf(url: string): string | null {
  try {
    return new URL(url).hostname || null;
  } catch {
    return null;
  }
}

// -- Saving ---------------------------------------------------------------

/** Everything one add writes in **a single write transaction**. The slug is made unique by the storage inside that transaction. */
export interface McpServerAddition {
  id: string;
  name: string;
  url: string;
  authKind: McpAuthKind;
  iconURL: string | null;
  createdAt: number;
  snapshots: McpToolSnapshot[];
  permissions: Record<string, McpToolPermission>;
  connectionState: McpConnectionState;
}

/** The server limit has been reached (carries the limit). */
export class McpServerLimitError extends Error {
  readonly max: number;
  constructor(max: number) {
    super(`MCP server limit reached: ${max}`);
    this.name = 'McpServerLimitError';
    this.max = max;
  }
}

/** What the add flow needs from server storage (the web production implementation lives in the app-layer store). */
export interface McpServerRepository {
  hasServer(id: string): Promise<boolean>;
  serverCount(): Promise<number>;
  /**
   * A single write transaction: makes the slug unique and writes the record, snapshot, permissions and
   * connection state, which all succeed or all do not exist. Throws `McpServerLimitError` at the limit;
   * throws without touching the existing row when the primary key collides with an existing server.
   */
  addServer(addition: McpServerAddition, maxServers: number): Promise<McpServerRecord>;
  deleteServer(id: string): Promise<void>;
}

export interface McpAddRequest extends Omit<McpProbeRequest, 'progress'> {
  /** The name the user entered; when empty, the name the server reports, then the host name. */
  name?: string;
  now?: number;
  progress?: McpAddProgress;
}

/**
 * Production entry point of the add flow: probe -> save -> emit **one** terminal state. After any failed
 * terminal state, neither storage nor credentials hold any trace of this add.
 */
export class McpAddCoordinator {
  private readonly probe: McpAddProbe;
  private readonly repository: McpServerRepository;
  private readonly credentialStore: McpCredentialStore;
  private readonly runtimeConfig: McpRuntimeConfig;

  constructor(options: {
    probe: McpAddProbe;
    repository: McpServerRepository;
    /** Must be the same one the probe and the authorizer use. */
    credentialStore: McpCredentialStore;
    runtimeConfig?: McpRuntimeConfig;
  }) {
    this.probe = options.probe;
    this.repository = options.repository;
    this.credentialStore = options.credentialStore;
    this.runtimeConfig = options.runtimeConfig ?? MCP_RUNTIME_CONFIG_FALLBACK;
  }

  /** Returns the terminal state; `progress` receives the progress states in order and then the terminal state exactly once (the return value). */
  async add(request: McpAddRequest): Promise<McpAddState> {
    const state = await this.perform(request);
    await request.progress?.(state);
    return state;
  }

  private async perform(request: McpAddRequest): Promise<McpAddState> {
    const checked = checkMcpEndpoint(request.url);
    if (!checked.ok) return { kind: 'invalidURL', reason: checked.reason };
    const endpoint = checked.url;

    // At the limit, or this id already is a server: reject before any request is sent. The former spares
    // the user a full browser sign-in before being told the server cannot be added; the latter because
    // failure cleanup deletes the credentials under this id and must never touch an existing server's token.
    try {
      if (await this.repository.hasServer(request.serverId)) return { kind: 'saveFailed' };
      if ((await this.repository.serverCount()) >= this.runtimeConfig.maxServers) {
        return { kind: 'limitReached', max: this.runtimeConfig.maxServers };
      }
    } catch {
      return { kind: 'saveFailed' };
    }

    const state = await this.probe.run({ ...request, url: endpoint });
    if (state.kind !== 'review') return state;
    const review = state.review;

    // One last cancellation check before saving: the user has left the add page, so no server may quietly appear.
    if (request.signal?.aborted) {
      await this.discardCredentials(request.serverId, request.uid);
      return { kind: 'cancelled' };
    }

    const now = request.now ?? Date.now();
    let record: McpServerRecord;
    try {
      record = await this.repository.addServer(
        {
          id: request.serverId,
          name: resolveServerName(request.name ?? '', review.session, endpoint),
          url: endpoint,
          authKind: request.authKind,
          iconURL: null,
          createdAt: now,
          snapshots: review.tools,
          permissions: review.defaultPermissions,
          connectionState: {
            serverId: request.serverId,
            status: 'connected',
            lastSuccessAt: now,
            negotiatedVersion: review.session.protocolVersion,
            generation: review.session.generation,
            sessionId: review.session.sessionId,
          },
        },
        this.runtimeConfig.maxServers,
      );
    } catch (error) {
      await this.discardCredentials(request.serverId, request.uid);
      if (error instanceof McpServerLimitError) return { kind: 'limitReached', max: error.max };
      return { kind: 'saveFailed' };
    }

    // A pasted access token has only lived in memory so far, and it is stored after the save: storing the
    // token first and being killed midway would leave a token without a server that nothing ever cleans up,
    // whereas the reverse is merely a server missing its token, which the user can see and delete.
    if (request.authKind === 'token' && request.token) {
      try {
        const current = await this.credentialStore.load(request.serverId, request.uid);
        await this.credentialStore.save({ ...(current ?? {}), pastedToken: request.token }, request.serverId, request.uid);
      } catch {
        // Token not stored = this server is unusable: treat it as a failed add and remove the record just written (it is certainly the one this add inserted).
        try {
          await this.repository.deleteServer(request.serverId);
        } catch {
          // Best effort.
        }
        await this.discardCredentials(request.serverId, request.uid);
        return { kind: 'saveFailed' };
      }
    }
    return state;
  }

  private async discardCredentials(serverId: string, uid: string): Promise<void> {
    try {
      await this.credentialStore.delete(serverId, uid);
    } catch {
      // See McpAddProbe.discardCredentials.
    }
  }
}

/** Fallback when the name is left empty: the name the server reports -> the host name. Capped at 64 UTF-16 code units without splitting a grapheme cluster. */
export function resolveServerName(name: string, session: Pick<McpSession, 'serverName'>, endpoint: string): string {
  const trimmed = name.trim();
  if (trimmed) return capServerName(trimmed);
  const reported = session.serverName?.trim();
  if (reported) return capServerName(reported);
  return capServerName(hostOf(endpoint) ?? 'MCP Server');
}

export function capServerName(name: string): string {
  const segments: string[] = [];
  const Segmenter = (Intl as { Segmenter?: new (locale?: string, options?: { granularity: 'grapheme' }) => { segment(input: string): Iterable<{ segment: string }> } }).Segmenter;
  if (Segmenter) {
    for (const { segment } of new Segmenter(undefined, { granularity: 'grapheme' }).segment(name)) segments.push(segment);
  } else {
    segments.push(...Array.from(name));
  }
  let result = '';
  for (const segment of segments) {
    if (result.length + segment.length > MCP_SERVER_MAX_NAME_LENGTH) break;
    result += segment;
  }
  return result || 'MCP Server';
}
