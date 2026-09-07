import type { RelayKind, RelayRequestedConfig } from '@oriveo/shared';
import { localizeProviderError } from './error-i18n';
import { networkError, toProviderError } from './errors';
import type { RelayErrorContext } from './relay-error-classifier';
import { getRelayRuntimeConfig } from '../metadata/metadata-client';
import { resolveRelayTransportRule } from './relay-runtime-support';
import { buildRelayGenerationValidationRequest } from '@oriveo/core/providers/relay-validation-request';
import type { RelayDirectFetchConfig } from '@oriveo/core/providers/relay-adapter';
import { buildBrowserRelayFetchArgs, fetchBrowserRelayDirect } from './relay-browser-direct';
import { isRelayGenerationSuccessResponse } from '@oriveo/core/providers/relay-generation-response';
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
}

export interface RelayPingRequest {
  method: 'POST';
  upstreamURL: string;
  directConfig: RelayDirectFetchConfig;
  baseHeaders: Record<string, string>;
  errorContext: RelayErrorContext;
  body?: Record<string, unknown>;
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
  credentials: Pick<RelayPingInput, 'apiKey' | 'plaintextKey' | 'relayRequested'>,
): RelayPingFailureDetails {
  if (!error || typeof error !== 'object') return {};
  const value = error as Record<string, unknown>;
  const sensitiveCredentialValues = relaySensitiveCredentialValues({
    apiKey: credentials.plaintextKey ?? credentials.apiKey,
    headers: credentials.relayRequested.headers,
    queryParams: credentials.relayRequested.queryParams,
  });
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

export function buildRelayPingRequest(input: RelayPingInput): RelayPingRequest {
  const transport: Exclude<RelayRequestedConfig['transport'], 'auto'> = input.relayRequested.transport === 'auto'
    ? 'openai_chat_completions'
    : input.relayRequested.transport;
  const authMode: Exclude<RelayRequestedConfig['authMode'], 'auto'> = input.relayRequested.authMode === 'auto'
    ? defaultAuthModeForTransport(transport)
    : input.relayRequested.authMode;
  const errorContext: RelayErrorContext = {
    isRelay: true,
    relayKind: input.relayKind,
    transport,
    authMode,
    modelID: input.modelID,
    codexCompatIdentity: input.relayRequested.codexCompatIdentity,
  };

  const request = buildRelayGenerationValidationRequest({
    baseURL: input.baseURL,
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
  });
  return { ...request, errorContext };
}

export async function pingRelay(input: RelayPingInput): Promise<RelayPingResult> {
  const request = buildRelayPingRequest(input);
  const sensitiveCredentialValues = relaySensitiveCredentialValues({
    apiKey: input.plaintextKey ?? input.apiKey,
    headers: input.relayRequested.headers,
    queryParams: input.relayRequested.queryParams,
  });

  const fetchArgs = buildBrowserRelayFetchArgs(
    request.upstreamURL,
    request.baseHeaders,
    { ...request.directConfig, method: request.method },
  );
  const response = await fetchBrowserRelayDirect(fetchArgs.url, {
    method: request.method,
    headers: {
      'Content-Type': 'application/json',
      ...fetchArgs.headers,
    },
    body: request.body ? JSON.stringify(request.body) : undefined,
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    throw toProviderError(
      response.status,
      detail,
      request.upstreamURL,
      request.errorContext,
      sensitiveCredentialValues,
    );
  }

  const body = await response.text().catch(() => '');
  if (!isRelayGenerationSuccessResponse(body, response.headers.get('Content-Type'))) {
    throw toProviderError(
      response.status,
      'The relay returned an HTML page instead of a generation response.',
      request.upstreamURL,
      request.errorContext,
      sensitiveCredentialValues,
    );
  }

  return { modelCount: 0, probedEndpoint: request.probedEndpoint };
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
