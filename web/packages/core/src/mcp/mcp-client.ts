/**
 * Remote MCP protocol client (dual-era). Its behaviour mirrors the iOS `McpClient.swift`.
 *
 * Covers probing and negotiation across both protocol generations, request shapes, `tools/list`,
 * `tools/call`, MRTR, the runtime configuration, call / cancel / retry / resource limits and the closed
 * set of error codes. A `tools/call` is never retried once it has been sent, and credentials never
 * follow a redirect to another origin (see `mcp-transport.ts`).
 *
 * Streamable HTTP over https only: JSON-RPC is POSTed to the server URL and the response is either a
 * single JSON document or an SSE stream. Networking goes through the injected `McpTransport` (public
 * hosts via the app's own forwarder, private hosts directly); this file does not know which path is used.
 */

import { isJsonObject, jsonField, jsonInteger, jsonString, parseJsonLimited } from './mcp-json';
import { orderedJsonString, utf8Bytes } from './mcp-pure';
import { McpSseParser, parseSseMessages } from './mcp-sse';
import {
  MCP_MAX_RESPONSE_BYTES,
  McpBodyTooLargeError,
  McpTransportError,
  isHttpsUrl,
  readBodyText,
  tryParseUrl,
  type McpHttpResponse,
  type McpTransport,
} from './mcp-transport';
import {
  MCP_CLIENT_INFO,
  MCP_INVALID_PARAMS_ERROR,
  MCP_LEGACY_INITIALIZE_VERSION,
  MCP_LEGACY_VERSIONS,
  MCP_MAX_TOOLS_LIST_PAGES,
  MCP_META_CLIENT_CAPABILITIES,
  MCP_META_CLIENT_INFO,
  MCP_META_PROTOCOL_VERSION,
  MCP_METHOD_NOT_FOUND_ERROR,
  MCP_MODERN_ERROR_CODES,
  MCP_MODERN_VERSION,
  MCP_RUNTIME_CONFIG_FALLBACK,
  MCP_UNSUPPORTED_VERSION_ERROR,
  containsModernMarker,
  parseToolDefinition,
  type JsonValue,
  type McpErrorCode,
  type McpProtocolGeneration,
  type McpRuntimeConfig,
  type McpToolDefinition,
} from './mcp-types';
import { parseWwwAuthenticate, requiresAuthResponse, type McpAuthChallenge } from './mcp-www-authenticate';

/** Result of one successful negotiation. The session id lives only in memory and in the local connection state; it is never logged. */
export interface McpSession {
  generation: McpProtocolGeneration;
  protocolVersion: string;
  sessionId: string | null;
  /** Name the server reports for itself (legacy: `serverInfo.name` from `initialize`; `null` when the modern probe cannot learn it). */
  serverName: string | null;
}

/**
 * Protocol client error. `code` belongs to the closed set of MCP error codes; `detail` is the server's own
 * text (truncated to 200 characters), used only for the on-device step payload and the user-visible failure
 * description. It **never goes into `toolSteps`, logs or analytics**.
 * `message` carries only the error code, so printing the error does not leak the server's text.
 */
export class McpClientError extends Error {
  readonly code: McpErrorCode;
  readonly detail: string | null;
  constructor(code: McpErrorCode, detail?: string | null) {
    super(`MCP client error: ${code}`);
    this.name = 'McpClientError';
    this.code = code;
    this.detail = detail ? Array.from(detail).slice(0, 200).join('') : null;
  }
}

/**
 * Terminal states of probing and negotiation. `notMcp` / `unreachable` / `needsAuth` are not error codes;
 * they are intermediate results of the add-server state machine. `failed` carries one of `server_error` /
 * `timeout` / `cancelled`.
 */
export type McpConnectOutcome =
  | { kind: 'connected'; session: McpSession }
  | { kind: 'notMcp' }
  | { kind: 'needsAuth' }
  | { kind: 'unreachable' }
  | { kind: 'failed'; error: McpClientError };

/** Outcome of one `tools/call`. `isError` and MRTR are both **normal results**; only transport and protocol failures throw. */
export interface McpToolCallResult {
  /** Text fed back to the model, after trimming. */
  text: string;
  isError: boolean;
  /** `tool_error` / `needs_input_unsupported` / `result_too_large` (analytics only), or `null`. */
  errorCode: McpErrorCode | null;
  truncated: boolean;
  structuredContent: JsonValue | null;
}

export const MCP_TRUNCATION_MARKER = '\n\n[result truncated]';
const ACCEPT_HEADER = 'application/json, text/event-stream';
/** Upper bound for waiting on a legacy cancel notification: it is a best-effort side request and must not hang for the full call timeout. */
const CANCEL_NOTIFICATION_TIMEOUT_MS = 5_000;

export interface McpCallOptions {
  /** The caller's cancellation signal (the user pressed stop). Aborting closes this request's response stream. */
  signal?: AbortSignal;
}

export interface McpClientOptions {
  endpoint: string;
  transport: McpTransport;
  runtimeConfig?: McpRuntimeConfig;
}

/** Result of one JSON-RPC exchange. */
interface McpExchange {
  status: number;
  headers: McpHttpResponse['headers'];
  /** JSON-RPC response matching this request's id; `null` when the body is empty, is not JSON-RPC, or no id matches. */
  message: { [key: string]: JsonValue } | null;
  /** The body holds JSON-RPC responses, but none of them matches this request's id. */
  mismatchedID: boolean;
}

interface OutgoingRequest {
  headers: Record<string, string>;
  body: string;
}

type InitializeOutcome =
  | { kind: 'session'; session: McpSession }
  | { kind: 'needsAuth' }
  | { kind: 'notMcp' }
  | { kind: 'rejected'; error: McpClientError };

/** Remote MCP protocol client. One instance per server URL; the negotiation result is cached on the instance. */
export class McpClient {
  private readonly endpoint: string;
  private readonly transport: McpTransport;
  private readonly runtimeConfig: McpRuntimeConfig;
  private bearerToken: string | null = null;
  private negotiated: McpSession | null = null;
  private lastChallenge: McpAuthChallenge | null = null;
  private nextRequestId = 1;
  /** In-flight exchanges; `cancel()` aborts each of them. */
  private readonly inFlight = new Set<AbortController>();

  constructor(options: McpClientOptions) {
    this.endpoint = options.endpoint;
    this.transport = options.transport;
    this.runtimeConfig = options.runtimeConfig ?? MCP_RUNTIME_CONFIG_FALLBACK;
  }

  /** The currently negotiated session (`null` until negotiation succeeds). */
  get session(): McpSession | null {
    return this.negotiated;
  }

  /** Challenge from the most recent 401 / 403 `insufficient_scope`; discovery prefers its `resource_metadata`. */
  get authChallenge(): McpAuthChallenge | null {
    return this.lastChallenge;
  }

  /** Swaps the token (after a refresh). Does not renegotiate. */
  setBearerToken(token: string | null): void {
    this.bearerToken = token;
  }

  /**
   * Reuses the generation verdict cached in the local connection state (the verdict is a property of the
   * server and SHOULD be cached). Later calls skip probing; when the session turns out to be invalid,
   * `listTools` / `callTool` redo the handshake once.
   */
  restoreSession(session: McpSession, bearerToken: string | null = this.bearerToken): void {
    this.negotiated = { ...session };
    this.bearerToken = bearerToken;
  }

  // ── Probing and negotiation ──────────────────────────────────────────

  /**
   * 1. Send a modern-shaped `tools/list` first; 2. success → stateless; 3. 400 (or 200 + JSON-RPC error) →
   * **read the body first**: only a recognizable modern error prevents the fallback, anything else falls
   * back to `initialize`; 4. 404 with a JSON-RPC body → modern, a bare 404 → not MCP;
   * 5. network-level failure → `unreachable`, with no retry of the generation probe.
   */
  async connect(options: McpCallOptions & { bearerToken?: string | null } = {}): Promise<McpConnectOutcome> {
    this.bearerToken = options.bearerToken ?? null;
    this.negotiated = null;
    this.lastChallenge = null;
    let outcome: McpConnectOutcome;
    try {
      outcome = await this.performConnect(options.signal);
    } catch (error) {
      if (error instanceof McpClientError) {
        if (error.code === 'timeout' || error.code === 'cancelled' || error.code === 'server_error') {
          return { kind: 'failed', error };
        }
      }
      return { kind: 'unreachable' };
    }
    if (outcome.kind === 'connected') this.negotiated = outcome.session;
    return outcome;
  }

  private async performConnect(signal?: AbortSignal): Promise<McpConnectOutcome> {
    const probe = await this.modernProbe(signal);
    if (this.requiresAuth(probe)) return { kind: 'needsAuth' };

    const probeError = probe.message?.error;
    if (probeError !== undefined && (probe.status === 400 || probe.status === 200)) {
      // Some legacy servers answer "not initialized yet" with 200 + JSON-RPC error instead of 400; same rule applies.
      return this.resolveProbeError(probeError, signal);
    }

    switch (probe.status) {
      case 200:
        if (isToolsListResult(probe.message)) return { kind: 'connected', session: modernSession() };
        if (probe.mismatchedID) return failed('server_error');
        return { kind: 'notMcp' };
      case 400:
        return this.legacyHandshake(MCP_LEGACY_INITIALIZE_VERSION, signal);
      case 404:
        if (probe.message) return failed('server_error', errorMessage(probe.message.error));
        return { kind: 'notMcp' };
      case 405:
        return { kind: 'notMcp' };
      default:
        if (probe.status >= 200 && probe.status < 300) return { kind: 'notMcp' };
        return failed('server_error');
    }
  }

  /** Routes a JSON-RPC error received by the probe. */
  private async resolveProbeError(error: JsonValue, signal?: AbortSignal): Promise<McpConnectOutcome> {
    if (!isRecognizableModernError(error)) {
      return this.legacyHandshake(MCP_LEGACY_INITIALIZE_VERSION, signal);
    }
    const detail = errorMessage(error);
    if (jsonInteger(jsonField(error, 'code')) !== MCP_UNSUPPORTED_VERSION_ERROR) return failed('server_error', detail);

    const supportedRaw = jsonField(jsonField(error, 'data'), 'supported');
    const supported = Array.isArray(supportedRaw) ? supportedRaw.filter((v): v is string => typeof v === 'string') : [];
    if (supported.includes(MCP_MODERN_VERSION)) {
      const retry = await this.modernProbe(signal);
      if (this.requiresAuth(retry)) return { kind: 'needsAuth' };
      if (retry.status === 200 && isToolsListResult(retry.message)) {
        return { kind: 'connected', session: modernSession() };
      }
      return failed('server_error', errorMessage(retry.message?.error));
    }
    // The server only lists legacy versions: resending the modern shape is pointless, so handshake with the highest one we support.
    const legacy = MCP_LEGACY_VERSIONS.find((version) => supported.includes(version));
    if (legacy) return this.legacyHandshake(legacy, signal);
    return failed('server_error', detail);
  }

  private modernProbe(signal?: AbortSignal): Promise<McpExchange> {
    const id = this.nextId();
    const request = this.makeRequest(id, 'tools/list', {}, null, modernSession());
    return this.exchange(request, id, { allowPreConnectRetry: false, signal });
  }

  /** Legacy handshake: `initialize` → `initialized`. */
  private async legacyHandshake(version: string, signal?: AbortSignal): Promise<McpConnectOutcome> {
    const outcome = await this.performInitialize(version, signal);
    switch (outcome.kind) {
      case 'session':
        await this.sendInitializedNotification(outcome.session, signal);
        return { kind: 'connected', session: outcome.session };
      case 'needsAuth':
        return { kind: 'needsAuth' };
      case 'notMcp':
        // Neither the modern probe nor the fallback handshake holds (an ordinary website answering 400 to a JSON POST ends up here).
        return { kind: 'notMcp' };
      case 'rejected':
        return { kind: 'failed', error: outcome.error };
    }
  }

  private async performInitialize(version: string, signal?: AbortSignal): Promise<InitializeOutcome> {
    const id = this.nextId();
    const request = this.makeInitializeRequest(id, version);
    const response = await this.exchange(request, id, { allowPreConnectRetry: false, signal });
    if (this.requiresAuth(response)) return { kind: 'needsAuth' };
    if (response.status >= 500) return { kind: 'rejected', error: new McpClientError('server_error') };
    const message = response.message;
    if (!message) {
      return response.mismatchedID ? { kind: 'rejected', error: new McpClientError('server_error') } : { kind: 'notMcp' };
    }
    if (message.error !== undefined) {
      // Every legacy server implements initialize; one that lacks even this method is some other JSON-RPC service.
      if (jsonInteger(jsonField(message.error, 'code')) === MCP_METHOD_NOT_FOUND_ERROR) return { kind: 'notMcp' };
      return { kind: 'rejected', error: new McpClientError('server_error', errorMessage(message.error)) };
    }
    const result = message.result;
    const negotiated = jsonString(jsonField(result, 'protocolVersion'));
    if (response.status < 200 || response.status >= 300 || !isJsonObject(result) || !negotiated) {
      return { kind: 'notMcp' };
    }
    // The server answered with a version we do not support: disconnect, as the specification requires.
    if (!MCP_LEGACY_VERSIONS.includes(negotiated)) {
      return { kind: 'rejected', error: new McpClientError('server_error') };
    }
    return {
      kind: 'session',
      session: {
        generation: 'session',
        protocolVersion: negotiated,
        sessionId: response.headers.get('mcp-session-id'),
        serverName: jsonString(jsonField(jsonField(result, 'serverInfo'), 'name')) ?? null,
      },
    };
  }

  private async sendInitializedNotification(session: McpSession, signal?: AbortSignal): Promise<void> {
    const request = this.makeNotificationRequest('notifications/initialized', null, session);
    try {
      await this.exchange(request, null, { allowPreConnectRetry: false, signal });
    } catch {
      // A notification has no response to wait for; failing to send it does not change the handshake outcome.
    }
  }

  /** Redoes the handshake once after the server terminated a legacy session; stores the new session on success. */
  private async reinitialize(signal?: AbortSignal): Promise<McpSession | null> {
    const outcome = await this.performInitialize(MCP_LEGACY_INITIALIZE_VERSION, signal);
    if (outcome.kind !== 'session') return null;
    await this.sendInitializedNotification(outcome.session, signal);
    this.negotiated = outcome.session;
    return outcome.session;
  }

  // ── tools/list ───────────────────────────────────────────────────────

  /** Fetches the full tool list. Pagination must be followed to the end; at most 20 pages per call, beyond that it is a failure. */
  async listTools(options: McpCallOptions = {}): Promise<McpToolDefinition[]> {
    let session = this.negotiated;
    if (!session) throw new McpClientError('server_error');
    let tools: McpToolDefinition[] = [];
    let cursor: string | null = null;
    let pages = 0;
    let didReinitialize = false;

    while (true) {
      if (pages >= MCP_MAX_TOOLS_LIST_PAGES) throw new McpClientError('server_error');
      pages += 1;
      const id = this.nextId();
      const params: Record<string, JsonValue> = cursor ? { cursor } : {};
      const request = this.makeRequest(id, 'tools/list', params, null, session);
      const response = await this.send(request, id, session, { allowPreConnectRetry: true, signal: options.signal });
      if (this.requiresAuth(response)) throw new McpClientError('needs_auth');

      // The server terminated the legacy session (404): initialize again once, never retry indefinitely.
      if (session.generation === 'session' && response.status === 404 && !didReinitialize) {
        didReinitialize = true;
        const renegotiated = await this.reinitialize(options.signal);
        if (renegotiated) {
          session = renegotiated;
          // Cursors issued by the old session mean nothing in the new one; start over.
          tools = [];
          cursor = null;
          pages = 0;
          continue;
        }
      }

      const result = response.message?.result;
      if (!isJsonObject(result)) {
        throw new McpClientError('server_error', errorMessage(response.message?.error));
      }
      const list = result.tools;
      if (Array.isArray(list)) {
        for (const raw of list) {
          const definition = parseToolDefinition(raw);
          if (definition) tools.push(definition);
        }
      }
      const next = jsonString(result.nextCursor);
      if (next) {
        cursor = next;
        continue;
      }
      return tools;
    }
  }

  // ── tools/call ───────────────────────────────────────────────────────

  /** Calls one tool. Tool execution errors and MRTR come back as results; transport and protocol failures throw `McpClientError`. */
  async callTool(name: string, args: JsonValue, options: McpCallOptions = {}): Promise<McpToolCallResult> {
    const session = this.negotiated;
    if (!session) throw new McpClientError('server_error');
    const id = this.nextId();
    const request = this.makeRequest(id, 'tools/call', { name, arguments: args }, name, session);
    // Never retry automatically once tools/call has been sent (replaying a writing tool would write twice).
    const response = await this.send(request, id, session, { allowPreConnectRetry: false, signal: options.signal });
    if (this.requiresAuth(response)) throw new McpClientError('needs_auth');

    // The legacy session was terminated: initialize again once to recover it, but **do not replay this call**.
    if (session.generation === 'session' && response.status === 404) {
      try {
        await this.reinitialize(options.signal);
      } catch {
        // A failed recovery does not change the outcome of this call.
      }
      throw new McpClientError('server_error', errorMessage(response.message?.error));
    }

    const message = response.message;
    if (!message) throw new McpClientError('server_error');
    if (message.error !== undefined) {
      const detail = errorMessage(message.error);
      // Protocol errors such as an unknown tool are treated as tool_error (fixture error.unknown-tool.json).
      if (jsonInteger(jsonField(message.error, 'code')) === MCP_INVALID_PARAMS_ERROR) {
        throw new McpClientError('tool_error', detail);
      }
      throw new McpClientError('server_error', detail);
    }
    const result = message.result;
    if (!isJsonObject(result)) throw new McpClientError('server_error');

    // MRTR: decided by resultType alone, never by method names such as elicitation/create.
    if (result.resultType === 'input_required') {
      return { text: '', isError: false, errorCode: 'needs_input_unsupported', truncated: false, structuredContent: null };
    }

    const trimmed = this.trim(result);
    const isError = result.isError === true;
    return {
      text: trimmed.text,
      isError,
      errorCode: isError ? 'tool_error' : trimmed.truncated || trimmed.droppedStructured ? 'result_too_large' : null,
      truncated: trimmed.truncated,
      structuredContent: trimmed.structuredContent,
    };
  }

  // ── Cancellation ─────────────────────────────────────────────────────

  /** Cancels every in-flight request on this client (closing the response stream is the cancellation). To cancel a single call, abort its `signal`. */
  cancel(): void {
    for (const controller of this.inFlight) controller.abort('cancelled');
  }

  /**
   * A client that no longer needs a legacy session SHOULD send `DELETE` + `MCP-Session-Id` (the server may
   * answer 405). Best effort; failures are ignored.
   */
  async closeSession(): Promise<void> {
    const session = this.negotiated;
    if (!session || session.generation !== 'session' || !session.sessionId) return;
    try {
      const response = await this.transport.send({
        url: this.endpoint,
        method: 'DELETE',
        headers: { 'mcp-protocol-version': session.protocolVersion, 'mcp-session-id': session.sessionId },
        credential: this.bearerToken,
        redirect: 'same-origin',
      });
      await response.body?.cancel().catch(() => {});
    } catch {
      // Best effort.
    }
  }

  // ── Result trimming ──────────────────────────────────────────────────

  private trim(result: { [key: string]: JsonValue }): {
    text: string;
    truncated: boolean;
    structuredContent: JsonValue | null;
    droppedStructured: boolean;
  } {
    const parts: string[] = [];
    if (Array.isArray(result.content)) {
      for (const item of result.content) {
        const type = jsonString(jsonField(item, 'type'));
        const text = jsonString(jsonField(item, 'text'));
        if (type === 'text' && text !== undefined) parts.push(text);
        else parts.push(`[non-text content: ${type ?? 'unknown'}]`);
      }
    }
    let text = parts.join('');
    const limit = this.maxResultChars;
    let structured: JsonValue | null = result.structuredContent ?? null;
    let droppedStructured = false;
    if (result.structuredContent !== undefined) {
      const serialized = orderedJsonString(result.structuredContent);
      if (text.length === 0) text = serialized;
      // Truncated JSON is not JSON: drop an oversized value entirely rather than let an 8 MB object slip past the limit.
      if (codePointLength(serialized, limit) > limit) {
        structured = null;
        droppedStructured = true;
      }
    }
    if (codePointLength(text, limit) <= limit) return { text, truncated: false, structuredContent: structured, droppedStructured };
    const keep = Math.max(0, limit - MCP_TRUNCATION_MARKER.length);
    return {
      text: Array.from(text).slice(0, keep).join('') + MCP_TRUNCATION_MARKER,
      truncated: true,
      structuredContent: structured,
      droppedStructured,
    };
  }

  private get callTimeoutMs(): number {
    const seconds = this.runtimeConfig.callTimeoutSeconds > 0
      ? this.runtimeConfig.callTimeoutSeconds
      : MCP_RUNTIME_CONFIG_FALLBACK.callTimeoutSeconds;
    // When the transport has a ceiling (the web client goes through the app's forwarder) it caps the call timeout:
    // the transport timeout must be strictly greater than the call timeout.
    const ceiling = this.transport.callTimeoutCeilingSeconds?.(this.endpoint) ?? null;
    return (ceiling !== null && ceiling > 0 ? Math.min(seconds, ceiling) : seconds) * 1000;
  }

  private get maxResultChars(): number {
    return this.runtimeConfig.maxResultChars > 0 ? this.runtimeConfig.maxResultChars : MCP_RUNTIME_CONFIG_FALLBACK.maxResultChars;
  }

  // ── Authorization challenge ──────────────────────────────────────────

  private requiresAuth(response: McpExchange): boolean {
    const header = response.headers.get('www-authenticate');
    if (!requiresAuthResponse(response.status, header)) return false;
    this.lastChallenge = parseWwwAuthenticate(header);
    return true;
  }

  // ── Request construction ─────────────────────────────────────────────

  private nextId(): number {
    return this.nextRequestId++;
  }

  private baseHeaders(session: McpSession | null): Record<string, string> {
    const headers: Record<string, string> = { accept: ACCEPT_HEADER, 'content-type': 'application/json' };
    // initialize itself carries no MCP-Protocol-Version (the specification requires it on subsequent requests).
    if (session) {
      headers['mcp-protocol-version'] = session.protocolVersion;
      if (session.generation === 'session' && session.sessionId) headers['mcp-session-id'] = session.sessionId;
    }
    return headers;
  }

  /** Shared by both generations: modern sends `_meta` plus `Mcp-Method` / `Mcp-Name` on every request; legacy sends only the version and session id. */
  private makeRequest(
    id: number,
    method: string,
    params: Record<string, JsonValue>,
    toolName: string | null,
    session: McpSession,
  ): OutgoingRequest {
    const headers = this.baseHeaders(session);
    const body: Record<string, JsonValue> = { ...params };
    if (session.generation === 'stateless') {
      body._meta = modernMeta(session.protocolVersion);
      headers['mcp-method'] = method;
      if (toolName !== null) headers['mcp-name'] = encodeHeaderValue(toolName);
    }
    return { headers, body: JSON.stringify({ jsonrpc: '2.0', id, method, params: body }) };
  }

  private makeInitializeRequest(id: number, version: string): OutgoingRequest {
    return {
      headers: this.baseHeaders(null),
      body: JSON.stringify({
        jsonrpc: '2.0',
        id,
        method: 'initialize',
        params: { protocolVersion: version, capabilities: { tools: {} }, clientInfo: { ...MCP_CLIENT_INFO } },
      }),
    };
  }

  private makeNotificationRequest(method: string, params: JsonValue | null, session: McpSession): OutgoingRequest {
    const message: Record<string, JsonValue> = { jsonrpc: '2.0', method };
    if (params !== null) message.params = params;
    return { headers: this.baseHeaders(session), body: JSON.stringify(message) };
  }

  // ── Transport ────────────────────────────────────────────────────────

  /** Sends a request that belongs to a negotiated session. On cancellation the legacy protocol also sends a cancel notification. */
  private async send(
    request: OutgoingRequest,
    id: number,
    session: McpSession,
    options: { allowPreConnectRetry: boolean; signal?: AbortSignal },
  ): Promise<McpExchange> {
    try {
      return await this.exchange(request, id, options);
    } catch (error) {
      if (error instanceof McpClientError && error.code === 'cancelled' && session.generation === 'session') {
        this.sendCancelledNotification(id, session);
      }
      throw error;
    }
  }

  /**
   * Legacy cancel notification: closing the response stream already cancels; this merely tells a legacy
   * server it can stop working. Best effort: it is not awaited and failures are ignored. The modern
   * protocol has no such notification over Streamable HTTP.
   */
  private sendCancelledNotification(requestId: number, session: McpSession): void {
    const request = this.makeNotificationRequest(
      'notifications/cancelled',
      { requestId, reason: 'User requested cancellation' },
      session,
    );
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort('timeout'), CANCEL_NOTIFICATION_TIMEOUT_MS);
    void this.transport
      .send({
        url: this.endpoint,
        method: 'POST',
        headers: request.headers,
        body: request.body,
        credential: this.bearerToken,
        redirect: 'same-origin',
        signal: controller.signal,
      })
      .then((response) => response.body?.cancel())
      .catch(() => {})
      .finally(() => clearTimeout(timer));
  }

  /**
   * One HTTP exchange. The caller's `signal` aborting or someone calling `cancel()` → `cancelled`; exceeding
   * `callTimeoutSeconds` → `timeout`; network-level failure → `unreachable`; oversized response body →
   * `server_error`.
   * A `null` `requestId` means a notification (no response body is awaited).
   */
  private async exchange(
    request: OutgoingRequest,
    requestId: number | null,
    options: { allowPreConnectRetry: boolean; signal?: AbortSignal },
  ): Promise<McpExchange> {
    // Second gate on top of URL validation: the client itself never sends anything (tokens included) to a non-https URL.
    const endpoint = tryParseUrl(this.endpoint);
    if (!endpoint || !isHttpsUrl(endpoint)) throw new McpClientError('unreachable');
    if (options.signal?.aborted) throw new McpClientError('cancelled');

    for (let attempt = 0; ; attempt++) {
      try {
        return await this.attempt(request, requestId, options.signal);
      } catch (error) {
        if (
          options.allowPreConnectRetry &&
          attempt === 0 &&
          error instanceof McpClientError &&
          error.code === 'unreachable' &&
          error.detail === PRE_CONNECT
        ) {
          continue;
        }
        if (error instanceof McpClientError && error.detail === PRE_CONNECT) throw new McpClientError('unreachable');
        throw error;
      }
    }
  }

  private async attempt(
    request: OutgoingRequest,
    requestId: number | null,
    signal: AbortSignal | undefined,
  ): Promise<McpExchange> {
    const controller = new AbortController();
    let reason: 'cancelled' | 'timeout' | 'done' | null = null;
    const onCallerAbort = () => {
      reason ??= 'cancelled';
      controller.abort('cancelled');
    };
    signal?.addEventListener('abort', onCallerAbort, { once: true });
    const timer = setTimeout(() => {
      reason ??= 'timeout';
      controller.abort('timeout');
    }, this.callTimeoutMs);
    // `cancel()` goes through controller.abort('cancelled'); recognize it here.
    controller.signal.addEventListener('abort', () => {
      if (reason === null) reason = 'cancelled';
    });
    this.inFlight.add(controller);
    try {
      let response: McpHttpResponse;
      try {
        response = await this.transport.send({
          url: this.endpoint,
          method: 'POST',
          headers: request.headers,
          body: request.body,
          credential: this.bearerToken,
          redirect: 'same-origin',
          signal: controller.signal,
        });
      } catch (error) {
        throw transportFailure(error, reason);
      }
      try {
        return await this.readExchange(response, requestId);
      } catch (error) {
        if (error instanceof McpBodyTooLargeError) throw new McpClientError('server_error');
        if (error instanceof McpClientError) throw error;
        if (reason === 'timeout') throw new McpClientError('timeout');
        if (reason === 'cancelled') throw new McpClientError('cancelled');
        throw new McpClientError('unreachable');
      }
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener('abort', onCallerAbort);
      this.inFlight.delete(controller);
      // Close the connection as soon as we have what we need: do not wait for the server to end the stream
      // (the final SSE response SHOULD terminate it, but that is not guaranteed).
      reason ??= 'done';
      controller.abort('done');
    }
  }

  /**
   * Retrieves the JSON-RPC response **matching this request's id**. SSE is parsed incrementally and returns
   * as soon as the matching final response arrives. Both forms are bound by the same 8 MB byte limit.
   */
  private async readExchange(response: McpHttpResponse, requestId: number | null): Promise<McpExchange> {
    const result: McpExchange = { status: response.status, headers: response.headers, message: null, mismatchedID: false };
    if (requestId === null) {
      await response.body?.cancel().catch(() => {});
      return result;
    }
    const declared = Number(response.headers.get('content-length'));
    if (Number.isFinite(declared) && declared > MCP_MAX_RESPONSE_BYTES) {
      await response.body?.cancel().catch(() => {});
      throw new McpBodyTooLargeError();
    }

    let candidates: JsonValue[] = [];
    const contentType = (response.headers.get('content-type') ?? '').toLowerCase();
    if (contentType.includes('text/event-stream') && response.body) {
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      const parser = new McpSseParser();
      let received = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          received += value.byteLength;
          if (received > MCP_MAX_RESPONSE_BYTES) throw new McpBodyTooLargeError();
          for (const message of parser.push(decoder.decode(value, { stream: true }))) {
            if (isResponseTo(message, requestId)) {
              result.message = message as { [key: string]: JsonValue };
              return result;
            }
            candidates.push(message);
          }
        }
        candidates.push(...parser.push(decoder.decode()), ...parser.finish());
      } finally {
        reader.cancel().catch(() => {});
      }
    } else {
      const text = await readBodyText(response.body, MCP_MAX_RESPONSE_BYTES);
      const parsed = parseJsonLimited(text);
      // Fall back to one more attempt as SSE when the Content-Type is not truthful.
      candidates = parsed !== undefined ? [parsed] : parseSseMessages(text);
    }

    const matched = candidates.find((message) => isResponseTo(message, requestId));
    result.message = matched && isJsonObject(matched) ? matched : null;
    // Notifications mixed into the stream have no result / error and do not count; a protocol error is a
    // message that has result / error yet matches no id.
    result.mismatchedID = result.message === null && candidates.some(isJsonRpcResponse);
    return result;
  }
}

// ── Helpers ──────────────────────────────────────────────────────────────

/** Internal marker: the failure happened before any response arrived (requests other than `tools/call` may be retried once). */
const PRE_CONNECT = '\u0000pre-connect';

function transportFailure(error: unknown, reason: 'cancelled' | 'timeout' | 'done' | null): McpClientError {
  if (reason === 'timeout') return new McpClientError('timeout');
  if (reason === 'cancelled') return new McpClientError('cancelled');
  if (error instanceof McpTransportError) {
    if (error.kind === 'timeout') return new McpClientError('timeout');
    if (error.kind === 'network') return new McpClientError('unreachable', PRE_CONNECT);
  }
  // Rejected redirects, non-https URLs and forwarder policy refusals are all "unreachable" and are not retried.
  return new McpClientError('unreachable');
}

function modernSession(): McpSession {
  return { generation: 'stateless', protocolVersion: MCP_MODERN_VERSION, sessionId: null, serverName: null };
}

function failed(code: McpErrorCode, detail?: string | null): McpConnectOutcome {
  return { kind: 'failed', error: new McpClientError(code, detail) };
}

/** Modern per-request `_meta`: `protocolVersion` and `clientCapabilities` are required, `clientInfo` is SHOULD. */
function modernMeta(version: string): JsonValue {
  return {
    [MCP_META_PROTOCOL_VERSION]: version,
    [MCP_META_CLIENT_INFO]: { ...MCP_CLIENT_INFO },
    [MCP_META_CLIENT_CAPABILITIES]: { tools: {} },
  };
}

/**
 * Value of a modern request header: visible ASCII is sent as is; values containing non-ASCII, control
 * characters, leading or trailing whitespace, or that themselves start with `=?base64?` are encoded as
 * `=?base64?{base64 of the UTF-8}?=`. Put into a header verbatim, non-ASCII would be rewritten and
 * the server would answer `-32020` when header and body disagree.
 */
export function encodeHeaderValue(value: string): string {
  const plain = /^[\x20-\x7e]*$/.test(value) && value === value.trim() && !value.startsWith('=?base64?');
  if (plain) return value;
  let binary = '';
  for (const byte of utf8Bytes(value)) binary += String.fromCharCode(byte);
  return `=?base64?${btoa(binary)}?=`;
}

function isToolsListResult(message: { [key: string]: JsonValue } | null): boolean {
  return Array.isArray(jsonField(message?.result, 'tools'));
}

/** (1) The code is -32022 / -32021 / -32020; (2) message or data contains a modern-only marker; (3) it carries `data.supported`. */
function isRecognizableModernError(error: JsonValue): boolean {
  const code = jsonInteger(jsonField(error, 'code'));
  if (code !== undefined && MCP_MODERN_ERROR_CODES.has(code)) return true;
  const data = jsonField(error, 'data');
  if (jsonField(data, 'supported') !== undefined) return true;
  const message = jsonString(jsonField(error, 'message'));
  if (message !== undefined && containsModernMarker(message)) return true;
  if (data !== undefined && containsModernMarker(orderedJsonString(data))) return true;
  return false;
}

function errorMessage(error: JsonValue | undefined): string | null {
  return jsonString(jsonField(error, 'message')) ?? null;
}

function isJsonRpcResponse(message: JsonValue): boolean {
  return (
    isJsonObject(message) &&
    message.jsonrpc === '2.0' &&
    (message.result !== undefined || message.error !== undefined)
  );
}

/**
 * Matches strictly by id and never falls back to "the first response in the stream": a response with a
 * mismatched id may be the result of another call. The only exception is what JSON-RPC allows, an error
 * with a `null` id (the server could not read the request id).
 */
function isResponseTo(message: JsonValue, requestId: number): boolean {
  if (!isJsonRpcResponse(message) || !isJsonObject(message)) return false;
  if (message.result === undefined && (message.id === undefined || message.id === null)) return true;
  return jsonInteger(message.id) === requestId;
}

/** Length in code points, stopping at `limit + 1` (only whether the limit is exceeded matters). */
function codePointLength(text: string, limit: number): number {
  if (text.length <= limit) return text.length;
  let count = 0;
  for (const _ of text) {
    count++;
    if (count > limit) break;
  }
  return count;
}
