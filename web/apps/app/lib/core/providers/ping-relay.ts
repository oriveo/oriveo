import type { AIModel, RelayKind, RelayRequestedConfig } from '@oriveo/shared';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { localizeProviderError } from './error-i18n';
import { networkError, toProviderError } from './errors';
import type { RelayErrorContext } from './relay-error-classifier';
import { getRelayRuntimeConfig } from '../metadata/metadata-client';
import { resolveRelayTransportRule } from './relay-runtime-support';
import {
  RELAY_PROBE_MAX_TOKENS,
  RELAY_PROBE_PROMPT,
  RELAY_PROBE_RESPONSES_MAX_OUTPUT_TOKENS,
  buildRelayGenerationValidationRequest,
  type RelayGenerationValidationConfig,
} from '@oriveo/core/providers/relay-validation-request';
import { normalizeBaseURL } from '@oriveo/core/providers/relay-adapter';
import { normalizeRelayBaseURL } from '@oriveo/core/providers/relay-endpoints';
import { relayProtocolUpstreamURL } from '@oriveo/core/providers/relay-orchestrator';
import { RELAY_HTML_PAGE_ERROR } from '@oriveo/core/providers/relay-stream';
import { buildBrowserRelayFetchArgs, fetchBrowserRelayDirect } from './relay-browser-direct';
import { buildRelayChatRequest } from './adapters/relay';
import { inferRelayHeaderProfile, relayFamilyHintForTransport } from './relay-resolution';
import { mergeRelayRuntime } from '../chat/stream-options';
import type { StreamOptions } from './types';
import { isRelayGenerationSuccessResponse } from '@oriveo/core/providers/relay-generation-response';
import { relayGenerationKeyStatus, type RelayGenerationKeyStatus } from '@oriveo/core/providers/relay-key-access';
import { relaySensitiveCredentialValues } from '@oriveo/core/providers/relay-runtime-support';
import { redactRelayCredentials } from '@oriveo/shared/relay/endpoint-policy';
import { extractErrorSnippet } from '@oriveo/core';

export interface RelayPingInput {
  baseURL: string;
  /** Plaintext key used only for this one verification of a new desktop draft; a saved connection must never set it. */
  plaintextKey?: string;
  apiKey: string;
  modelID: string;
  relayRequested: RelayRequestedConfig;
  relayKind?: RelayKind;
  /** The model being verified; when it sets its own protocol the request uses that protocol, otherwise it follows the connection default. */
  model?: Pick<AIModel, 'relayTransport'> | null;
  /**
   * For per-model probing: an API root already resolved through effectiveAPIRoot, used as is to build the
   * endpoint without appending a version segment per protocol. Defaults to `baseURL` (existing callers' requests are unchanged).
   */
  apiRoot?: string;
  /** Values of all keys of the connection: merged only into the local redaction list, never sent out. Defaults to masking just the current key. */
  connectionKeySecrets?: readonly string[];
  /** Aborts the in-flight request when the caller invalidates this verification (page left / input changed). */
  signal?: AbortSignal;
}

export interface RelayPingRequest {
  method: 'POST';
  /** Upstream endpoint (not the proxy address, no credential query): used for error attribution and the failure card. */
  upstreamURL: string;
  /** The wire shape actually sent (public addresses via the proxy, private ones direct), produced by the chat request builder. */
  url: string;
  headers: Record<string, string>;
  errorContext: RelayErrorContext;
  body: Record<string, unknown>;
  /** Shown to the user as "Connected via {probedEndpoint}." */
  probedEndpoint: string;
}

/** Real generation result of a connection check. Catalog sync is a separate step the caller runs after a successful check. */
export interface RelayPingResult {
  modelCount: number;
  probedEndpoint: string;
}

export interface RelayPingFailureDetails {
  requestURL?: string;
  statusCode?: number;
  upstreamMessage?: string;
}

/**
 * The failure card consumes only this safe projection: the upstream body still goes through the
 * allowlist extractor in core, and URLs keep origin and path only. Components must not render
 * ProviderError.detail directly, nor maintain a second redaction regex of their own.
 */
export function extractRelayPingFailureDetails(
  error: unknown,
  credentials: Pick<RelayPingInput, 'apiKey' | 'plaintextKey' | 'relayRequested' | 'connectionKeySecrets'>,
): RelayPingFailureDetails {
  if (!error || typeof error !== 'object') return {};
  const value = error as Record<string, unknown>;
  const sensitiveCredentialValues = relayPingRedactionValues(credentials);
  const upstreamMessage = typeof value.detail === 'string' && value.detail.trim()
    ? extractErrorSnippet(
        JSON.stringify({ error: { message: value.detail } }),
        500,
        sensitiveCredentialValues,
      )
    : undefined;
  return {
    statusCode: typeof value.status === 'number' ? value.status : undefined,
    requestURL: typeof value.upstreamURL === 'string'
      ? relayFailureDisplayURL(value.upstreamURL)
      : undefined,
    upstreamMessage,
  };
}

function relayFailureDisplayURL(raw: string): string | undefined {
  try {
    const url = new URL(raw);
    url.username = '';
    url.password = '';
    url.search = '';
    url.hash = '';
    return url.toString();
  } catch {
    return undefined;
  }
}

type RelayPingChatTransport = Exclude<RelayGenerationValidationConfig['transport'], 'llamacpp_native'>;

const PROBED_ENDPOINT: Readonly<Record<RelayPingChatTransport, string>> = {
  openai_responses: 'POST /responses',
  anthropic_messages: 'POST /v1/messages',
  gemini_generate_content: 'POST :generateContent',
  openai_chat_completions: 'POST /chat/completions',
};

/**
 * A probe is the chat request swapped for a one-sentence conversation: the ping for the four chat protocols is produced by
 * the same request builder the chat send uses (`buildRelayChatRequest`), so the headers and the identity / storage / cache
 * fields have the chat shape; only the conversation content, non-streaming and the output cap differ.
 * Tool and thinking fields are generation parameters and the probe omits them.
 * The llama.cpp native protocol has no pure-build entry for a chat request and keeps the core validation body.
 */
export function buildRelayPingRequest(input: RelayPingInput): RelayPingRequest {
  const { config, errorContext } = resolveRelayPingConfig(input);
  if (config.transport === 'llamacpp_native') {
    const request = buildRelayGenerationValidationRequest({ ...config, transport: 'llamacpp_native' });
    const fetchArgs = buildBrowserRelayFetchArgs(
      request.upstreamURL,
      request.baseHeaders,
      { ...request.directConfig, method: request.method },
    );
    return {
      method: request.method,
      upstreamURL: request.upstreamURL,
      url: fetchArgs.url,
      headers: { 'Content-Type': 'application/json', ...fetchArgs.headers },
      errorContext,
      body: request.body,
      probedEndpoint: request.probedEndpoint,
    };
  }
  // With no verification sample no request is sent: never hit the upstream on the user's behalf with a hardcoded model.
  const modelID = config.modelID.trim();
  if (!modelID) throw networkError('No model to verify this relay with.');
  const transport: RelayPingChatTransport = config.transport;
  const options = relayPingStreamOptions(input, config, transport);
  const wire = buildRelayChatRequest(
    config.apiKey,
    modelID,
    [{ role: 'user', content: RELAY_PROBE_PROMPT }],
    input.baseURL,
    options,
  );
  return {
    method: wire.method,
    upstreamURL: relayProtocolUpstreamURL(
      normalizeBaseURL(options.relayResolvedBaseURLText, options.relaySecurityMode),
      modelID,
      transport,
      options,
    ),
    url: wire.url,
    headers: wire.headers,
    errorContext,
    body: JSON.parse(wire.body) as Record<string, unknown>,
    probedEndpoint: PROBED_ENDPOINT[transport],
  };
}

/**
 * Chat options for the probe: the same field mapping as chat (`mergeRelayRuntime`), with the protocol / auth / root address
 * taken from what the ping resolved itself; it carries no user generation parameters, extra request body or connection-level web-search fragment.
 */
function relayPingStreamOptions(
  input: RelayPingInput,
  config: RelayGenerationValidationConfig,
  transport: RelayPingChatTransport,
): StreamOptions {
  const apiRoot = config.exactBaseURL
    ? config.baseURL
    : normalizeRelayBaseURL(config.baseURL, transport, config.securityMode);
  return {
    ...mergeRelayRuntime(
      { kind: 'relay', baseURLText: input.baseURL, relayRequested: input.relayRequested },
      {
        transport,
        apiRoot,
        authMode: config.authMode,
        headerProfile: inferRelayHeaderProfile(transport, config.authMode),
        familyHint: relayFamilyHintForTransport(transport),
      },
      undefined,
      false,
    ),
    relayStream: false,
    // No tools or thinking: the builder switch turns off the built-in tools and reasoning that Responses enables by default.
    relayOmitDefaultToolsAndReasoning: true,
    relayMaxOutputTokens: transport === 'openai_responses'
      ? RELAY_PROBE_RESPONSES_MAX_OUTPUT_TOKENS
      : RELAY_PROBE_MAX_TOKENS,
  };
}

/** Resolves the ping's protocol, auth (auto -> the protocol default) and root address. */
export function resolveRelayPingConfig(input: RelayPingInput): {
  config: RelayGenerationValidationConfig;
  errorContext: RelayErrorContext;
} {
  const transport = effectiveTransport(
    { baseURLText: input.baseURL, relayRequested: input.relayRequested },
    input.model,
  );
  const authMode: Exclude<RelayRequestedConfig['authMode'], 'auto'> = input.relayRequested.authMode === 'auto'
    ? defaultAuthModeForTransport(transport)
    : input.relayRequested.authMode;
  const errorContext: RelayErrorContext = {
    isRelay: true,
    relayKind: input.relayKind,
    transport,
    authMode,
    modelID: input.modelID,
  };

  const config: RelayGenerationValidationConfig = {
    baseURL: input.apiRoot ?? input.baseURL,
    exactBaseURL: input.apiRoot !== undefined,
    apiKey: input.apiKey,
    modelID: input.modelID,
    transport,
    authMode,
    securityMode: input.relayRequested.securityMode,
    codexCompatIdentity: input.relayRequested.codexCompatIdentity,
    customUserAgent: input.relayRequested.customUserAgent,
    headers: input.relayRequested.headers,
    queryParams: input.relayRequested.queryParams,
    disableResponseStorage: input.relayRequested.disableResponseStorage,
  };
  return { config, errorContext };
}

function connectionSecretsOf(values: readonly string[] | undefined): string[] {
  return (values ?? []).filter((value) => value.trim().length > 0);
}

/**
 * Redaction list for the failure reason and the technical details: all keys + every request-header value + every query-parameter value
 * + the custom User-Agent (the upstream echoes the headers and UA it received verbatim, so picking only by "sensitive name" would leak).
 */
function relayPingRedactionValues(
  credentials: Pick<RelayPingInput, 'apiKey' | 'plaintextKey' | 'relayRequested' | 'connectionKeySecrets'>,
): string[] {
  const requested = credentials.relayRequested;
  return [
    ...relaySensitiveCredentialValues({
      apiKey: credentials.plaintextKey ?? credentials.apiKey,
      headers: requested.headers,
      queryParams: requested.queryParams,
    }),
    ...connectionSecretsOf(credentials.connectionKeySecrets),
    ...connectionSecretsOf([
      ...(requested.headers ?? []).map((pair) => pair.value),
      ...(requested.queryParams ?? []).map((pair) => pair.value),
      requested.customUserAgent ?? '',
    ]),
  ];
}

export async function pingRelay(input: RelayPingInput): Promise<RelayPingResult> {
  const request = buildRelayPingRequest(input);
  const sensitiveCredentialValues = relayPingRedactionValues(input);

  const response = await fetchBrowserRelayDirect(request.url, {
    method: request.method,
    headers: request.headers,
    body: JSON.stringify(request.body),
    signal: input.signal,
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    // Compute the key status where the raw text is available and carry it on the error: the redacted detail can no longer show the top-level code.
    const relayKeyStatus = relayGenerationKeyStatus(response.status, detail);
    throw {
      ...toProviderError(
        response.status,
        detail,
        request.upstreamURL,
        request.errorContext,
        sensitiveCredentialValues,
      ),
      ...(relayKeyStatus ? { relayKeyStatus } : {}),
    };
  }

  const body = await response.text().catch(() => '');
  if (!isRelayGenerationSuccessResponse(body, response.headers.get('Content-Type'))) {
    throw {
      ...toProviderError(
        response.status,
        RELAY_HTML_PAGE_ERROR,
        request.upstreamURL,
        request.errorContext,
        sensitiveCredentialValues,
      ),
      relayHTMLPage: true as const,
    };
  }

  return { modelCount: 0, probedEndpoint: request.probedEndpoint };
}

/**
 * What a 1-token generation request says about the key status: success = ok; on failure only the invalid / limited that
 * pingRelay computed from the raw text counts, and everything else (network, HTML page, no access, route-level, 5xx) is null and leaves the status alone.
 */
export function relayPingKeyStatus(outcome: { ok: true } | { ok: false; error: unknown }): RelayGenerationKeyStatus | null {
  if (outcome.ok) return 'ok';
  const value = (outcome.error as { relayKeyStatus?: unknown } | null)?.relayKeyStatus;
  return value === 'invalid' || value === 'limited' ? value : null;
}

/**
 * pingRelay() throws a `ProviderError` plain object (kind/title/message/detail), not an Error
 * instance, so String(error) would render as "[object Object]".
 * Take the human-readable field by priority: message, then title, then detail, then a fallback string.
 */
type TranslationFn = (key: string) => string;

export function extractPingErrorMessage(error: unknown, t?: TranslationFn): string {
  if (error instanceof Error) return error.message;
  if (error && typeof error === 'object') {
    const obj = error as Record<string, unknown>;
    if (typeof obj.message === 'string' && obj.message.length > 0) {
      return t ? localizeProviderError(obj.message, t) : obj.message;
    }
    if (typeof obj.title === 'string' && obj.title.length > 0) return obj.title;
    if (typeof obj.detail === 'string' && obj.detail.length > 0) return obj.detail;
  }
  return String(error);
}

function defaultAuthModeForTransport(
  transport: Exclude<RelayRequestedConfig['transport'], 'auto'>,
): Exclude<RelayRequestedConfig['authMode'], 'auto'> {
  const rule = resolveRelayTransportRule(transport, getRelayRuntimeConfig());
  if (rule?.defaultAuthMode) return rule.defaultAuthMode;
  switch (transport) {
    case 'anthropic_messages':
      return 'x_api_key';
    case 'gemini_generate_content':
      return 'x_goog_api_key';
    case 'llamacpp_native':
      return 'none';
    case 'openai_chat_completions':
    case 'openai_responses':
      return 'bearer';
  }
}
