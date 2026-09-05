import type {
  AIModel,
  RelayAuthMode,
  RelayConnectionSecurityMode,
  RelayKeyValue,
} from '@oriveo/shared';
import { buildCatalogModel } from '../catalog-model';
import { buildDirectAuthHeaders } from '@oriveo/core/providers/relay-adapter';
import { isRelayGenerationSuccessResponse } from '@oriveo/core/providers/relay-generation-response';
import { relaySensitiveCredentialValues } from '@oriveo/core/providers/relay-runtime-support';
import { extractErrorSnippet } from '@oriveo/core/util/error-snippet';
import { buildBrowserRelayFetchArgs, fetchBrowserRelayDirect } from '../relay-browser-direct';
import {
  appendRelayEndpointPath,
  buildRelayEndpointCandidates,
  describeRelayEndpoint,
  type RelayEndpointCandidate,
  type RelayProbeTransportKind,
} from './endpoint-normalizer';

export { type RelayProbeTransportKind } from './endpoint-normalizer';

export type RelayDiscoveryFailureKind =
  | 'invalid_endpoint'
  | 'embedded_query'
  | 'authentication_rejected'
  | 'route_unavailable'
  | 'rate_limited'
  | 'temporary_failure'
  | 'invalid_response'
  | 'network'
  | 'generation_not_verified';

export type RelayDiscoveryAttemptKind = 'catalog' | 'generation_probe' | 'generation_verification';

export interface RelayDiscoveryAttempt {
  method: 'GET' | 'POST';
  requestURL: string;
  statusCode?: number;
  failure?: RelayDiscoveryFailureKind;
  kind: RelayDiscoveryAttemptKind;
  upstreamMessage?: string;
  retryCount: number;
}

export interface RelayDetectedConfiguration {
  transport: RelayProbeTransportKind;
  authMode: Exclude<RelayAuthMode, 'auto'>;
  apiBaseURL: string;
  modelIDs: string[];
  catalogModels: AIModel[];
  generationVerified: boolean;
  /** At least one real catalog request returned 2xx with a parseable shape; a legitimately empty catalog also counts as true. */
  catalogEvidenceSucceeded: boolean;
  detectionEvidence: 'catalog' | 'generation_probe';
}

/**
 * A successful generation probe proves the user-selected model is connected.
 * Catalog discovery remains independent: an empty or unavailable catalog must
 * not demote a 2xx generation result back to unverified.
 */
export function hasRelayConnectedEvidence(
  detection: RelayDetectedConfiguration | undefined,
): detection is RelayDetectedConfiguration {
  return detection?.generationVerified === true;
}

export interface RelayDiscoveryResult {
  state: 'verified' | 'needs_manual_model' | 'failed';
  detection?: RelayDetectedConfiguration;
  attempts: RelayDiscoveryAttempt[];
  failure?: RelayDiscoveryFailureKind;
  diagnostic?: string;
  retriedRequestCount: number;
}

export interface RelayDiscoveryInput {
  endpoint: string;
  apiKey: string;
  modelHint?: string;
  forcedTransport?: RelayProbeTransportKind;
  /** A reconnect after editing the connection has to use the security boundary the user chose; the default stays public HTTPS. */
  securityMode?: RelayConnectionSecurityMode;
  /** Editing validates against the saved auth mode; a new connection probes with the standard auth mode for the transport. */
  authMode?: Exclude<RelayAuthMode, 'auto'>;
  headers?: readonly RelayKeyValue[];
  queryParams?: readonly RelayKeyValue[];
  signal?: AbortSignal;
  retryBackoffMs?: readonly number[];
  sleep?: (durationMs: number, signal?: AbortSignal) => Promise<void>;
}

interface ResponseSnapshot {
  statusCode: number;
  body: string;
  contentType?: string;
  retryCount: number;
}

interface CatalogSnapshot {
  candidate: RelayEndpointCandidate;
  modelIDs: string[];
  catalogModels: AIModel[];
  transports: RelayProbeTransportKind[];
}

interface NetworkFailure extends Error {
  retryCount: number;
}

export const SENTINEL_PROBE_MODEL_ID = 'oriveo-endpoint-probe-no-such-model';
const DEFAULT_RETRY_BACKOFF_MS = [400, 1_200] as const;
const MAX_SAME_ORIGIN_REDIRECTS = 5;
const REQUEST_TIMEOUT_MS = 12_000;

/** Serial Relay discovery followed by a real one-token generation verification. */
export async function probeRelayEndpoint(input: RelayDiscoveryInput): Promise<RelayDiscoveryResult> {
  let descriptor;
  try {
    descriptor = describeRelayEndpoint(input.endpoint, input.securityMode);
  } catch {
    return failed('invalid_endpoint');
  }
  if (descriptor.containsEmbeddedQuery) return failed('embedded_query');

  const attempts: RelayDiscoveryAttempt[] = [];
  const transports = input.forcedTransport
    ? [input.forcedTransport]
    : transportOrder(
      descriptor.explicitTransport,
      descriptor.explicitVersion,
      input.modelHint,
      input.apiKey,
    );

  for (const transport of transports) {
    for (const candidate of buildRelayEndpointCandidates(descriptor, transport)) {
      const requestURL = appendRelayEndpointPath(candidate.apiBaseURL, 'models', input.securityMode);
      let snapshot: ResponseSnapshot;
      try {
        snapshot = await executeWithRetry({
          method: 'GET',
          requestURL,
          apiKey: input.apiKey,
          transport,
          authMode: input.authMode,
          securityMode: input.securityMode,
          headers: input.headers ? [...input.headers] : undefined,
          queryParams: input.queryParams ? [...input.queryParams] : undefined,
          signal: input.signal,
          retryBackoffMs: input.retryBackoffMs,
          sleep: input.sleep,
        });
      } catch (error) {
        if (isAbortError(error)) throw error;
        const network = error as NetworkFailure;
        attempts.push({
          method: 'GET',
          requestURL,
          failure: 'network',
          kind: 'catalog',
          upstreamMessage: network.message,
          retryCount: network.retryCount ?? 0,
        });
        return finishFailed(attempts, 'network');
      }

      const baseAttempt = {
        method: 'GET' as const,
        requestURL,
        statusCode: snapshot.statusCode,
        kind: 'catalog' as const,
        retryCount: snapshot.retryCount,
        upstreamMessage: extractDiagnostic(snapshot.body, input),
      };
      if (is2xx(snapshot.statusCode)) {
        const modelIDs = parseCatalogModelIDs(snapshot.body, transport);
        if (modelIDs === null) {
          attempts.push({ ...baseAttempt, failure: 'invalid_response' });
          continue;
        }
        attempts.push(baseAttempt);
        const catalog: CatalogSnapshot = {
          candidate,
          modelIDs,
          catalogModels: modelIDs.map((modelID) => buildRelayCatalogModel(modelID, transport)),
          transports: transport === 'openai_chat_completions' && !descriptor.explicitTransport
            ? ['openai_chat_completions', 'openai_responses']
            : [transport],
        };
        if (modelIDs.length === 0) {
          if (input.modelHint?.trim()) {
            return verifyCatalogDetection(input, catalog, attempts);
          }
          return finishDetected(attempts, {
            transport: catalog.transports[0],
            authMode: input.authMode ?? defaultAuthMode(catalog.transports[0]),
            apiBaseURL: candidate.apiBaseURL,
            modelIDs,
            catalogModels: [],
            generationVerified: false,
            catalogEvidenceSucceeded: true,
            detectionEvidence: 'catalog',
          });
        }
        return verifyCatalogDetection(input, catalog, attempts);
      }

      const failure = classifyStatus(snapshot.statusCode);
      attempts.push({ ...baseAttempt, failure });
      if (isBlockingFailure(failure)) return finishFailed(attempts, failure);
      if (failure !== 'route_unavailable') return finishFailed(attempts, failure);
    }
  }

  return probeGenerationRoutes(input, descriptor, attempts);
}

async function verifyCatalogDetection(
  input: RelayDiscoveryInput,
  catalog: CatalogSnapshot,
  attempts: RelayDiscoveryAttempt[],
): Promise<RelayDiscoveryResult> {
  const requestedModel = input.modelHint?.trim();
  const modelID = requestedModel || catalog.modelIDs[0];
  for (const transport of catalog.transports) {
    const request = generationRequest(
      catalog.candidate.apiBaseURL,
      transport,
      modelID,
      input.securityMode,
    );
    let snapshot: ResponseSnapshot;
    try {
      snapshot = await executeWithRetry({
        ...request,
        apiKey: input.apiKey,
        transport,
        authMode: input.authMode,
        securityMode: input.securityMode,
        headers: input.headers,
        queryParams: input.queryParams,
        signal: input.signal,
        retryBackoffMs: input.retryBackoffMs,
        sleep: input.sleep,
      });
    } catch (error) {
      if (isAbortError(error)) throw error;
      const network = error as NetworkFailure;
      attempts.push({
        method: 'POST',
        requestURL: request.requestURL,
        failure: 'network',
        kind: 'generation_verification',
        upstreamMessage: network.message,
        retryCount: network.retryCount ?? 0,
      });
      return finishFailed(attempts, 'network');
    }

    const baseAttempt = {
      method: 'POST' as const,
      requestURL: request.requestURL,
      statusCode: snapshot.statusCode,
      kind: 'generation_verification' as const,
      retryCount: snapshot.retryCount,
      upstreamMessage: extractDiagnostic(snapshot.body, input),
    };
    if (is2xx(snapshot.statusCode)) {
      if (!isRelayGenerationSuccessResponse(snapshot.body, snapshot.contentType)) {
        attempts.push({ ...baseAttempt, failure: 'invalid_response' });
        continue;
      }
      attempts.push(baseAttempt);
      return finishDetected(attempts, {
        transport,
        authMode: input.authMode ?? defaultAuthMode(transport),
        apiBaseURL: catalog.candidate.apiBaseURL,
        modelIDs: catalog.modelIDs,
        catalogModels: catalog.catalogModels,
        generationVerified: true,
        catalogEvidenceSucceeded: true,
        detectionEvidence: 'catalog',
      });
    }

    const failure = classifyStatus(snapshot.statusCode);
    attempts.push({ ...baseAttempt, failure });
    if (isBlockingFailure(failure)) return finishFailed(attempts, failure);
  }
  return finishFailed(attempts, 'generation_not_verified');
}

async function probeGenerationRoutes(
  input: RelayDiscoveryInput,
  descriptor: ReturnType<typeof describeRelayEndpoint>,
  attempts: RelayDiscoveryAttempt[],
): Promise<RelayDiscoveryResult> {
  const userModel = input.modelHint?.trim() ?? '';
  const modelID = userModel || SENTINEL_PROBE_MODEL_ID;
  const transports = input.forcedTransport
    ? [input.forcedTransport]
    : generationTransportOrder(
      descriptor.explicitTransport,
      descriptor.explicitVersion,
      input.modelHint,
      input.apiKey,
    );

  for (const transport of transports) {
    for (const candidate of buildRelayEndpointCandidates(descriptor, transport)) {
      const request = generationRequest(candidate.apiBaseURL, transport, modelID, input.securityMode);
      let snapshot: ResponseSnapshot;
      try {
        snapshot = await executeWithRetry({
          ...request,
          apiKey: input.apiKey,
          transport,
          authMode: input.authMode,
          securityMode: input.securityMode,
          headers: input.headers ? [...input.headers] : undefined,
          queryParams: input.queryParams ? [...input.queryParams] : undefined,
          signal: input.signal,
          retryBackoffMs: input.retryBackoffMs,
          sleep: input.sleep,
        });
      } catch (error) {
        if (isAbortError(error)) throw error;
        const network = error as NetworkFailure;
        attempts.push({
          method: 'POST',
          requestURL: request.requestURL,
          failure: 'network',
          kind: 'generation_probe',
          upstreamMessage: network.message,
          retryCount: network.retryCount ?? 0,
        });
        return finishFailed(attempts, 'network');
      }

      const baseAttempt = {
        method: 'POST' as const,
        requestURL: request.requestURL,
        statusCode: snapshot.statusCode,
        kind: 'generation_probe' as const,
        retryCount: snapshot.retryCount,
        upstreamMessage: extractDiagnostic(snapshot.body, input),
      };
      if (is2xx(snapshot.statusCode)) {
        if (!isRelayGenerationSuccessResponse(snapshot.body, snapshot.contentType)) {
          attempts.push({ ...baseAttempt, failure: 'invalid_response' });
          continue;
        }
        attempts.push(baseAttempt);
        return finishDetected(attempts, {
          transport,
          authMode: input.authMode ?? defaultAuthMode(transport),
          apiBaseURL: candidate.apiBaseURL,
          modelIDs: [],
          catalogModels: [],
          generationVerified: Boolean(userModel),
          catalogEvidenceSucceeded: false,
          detectionEvidence: 'generation_probe',
        });
      }
      if (snapshot.statusCode === 400 || snapshot.statusCode === 422) {
        attempts.push(baseAttempt);
        return finishDetected(attempts, {
          transport,
          authMode: input.authMode ?? defaultAuthMode(transport),
          apiBaseURL: candidate.apiBaseURL,
          modelIDs: [],
          catalogModels: [],
          generationVerified: false,
          catalogEvidenceSucceeded: false,
          detectionEvidence: 'generation_probe',
        });
      }

      const failure = classifyStatus(snapshot.statusCode);
      attempts.push({ ...baseAttempt, failure });
      if (isBlockingFailure(failure)) return finishFailed(attempts, failure);
      if (failure !== 'route_unavailable') return finishFailed(attempts, failure);
    }
  }

  const failure = attempts.some((attempt) => attempt.failure === 'invalid_response')
    ? 'invalid_response'
    : 'route_unavailable';
  return finishFailed(attempts, failure);
}

async function executeWithRetry(input: {
  method: 'GET' | 'POST';
  requestURL: string;
  body?: Record<string, unknown>;
  apiKey: string;
  transport: RelayProbeTransportKind;
  authMode?: Exclude<RelayAuthMode, 'auto'>;
  securityMode?: RelayConnectionSecurityMode;
  headers?: readonly RelayKeyValue[];
  queryParams?: readonly RelayKeyValue[];
  signal?: AbortSignal;
  retryBackoffMs?: readonly number[];
  sleep?: RelayDiscoveryInput['sleep'];
}): Promise<ResponseSnapshot> {
  const retryBackoffMs = input.retryBackoffMs ?? DEFAULT_RETRY_BACKOFF_MS;
  const sleep = input.sleep ?? abortableSleep;
  let retryCount = 0;

  while (true) {
    input.signal?.throwIfAborted();
    try {
      const authMode = input.authMode ?? defaultAuthMode(input.transport);
      const fetchArgs = buildBrowserRelayFetchArgs(
        input.requestURL,
        buildDirectAuthHeaders(input.apiKey, authMode),
        {
          transport: input.transport,
          authMode,
          apiKey: input.apiKey,
          method: input.method,
          securityMode: input.securityMode,
          headers: input.headers ? [...input.headers] : undefined,
          queryParams: input.queryParams ? [...input.queryParams] : undefined,
        },
      );
      const response = await fetchProbeFollowingSameOriginRedirects(fetchArgs.url, {
        method: input.method,
        headers: { Accept: 'application/json', 'Content-Type': 'application/json', ...fetchArgs.headers },
        body: input.body ? JSON.stringify(input.body) : undefined,
        credentials: 'omit',
        redirect: 'manual',
        signal: input.signal,
      }, input.securityMode);
      const body = await response.text();
      const isProxyNetworkFailure = response.headers.get('X-Oriveo-Error-Source') === 'network';
      if (
        isProxyNetworkFailure
        && isRetryableProxyNetworkFailure(body)
        && retryCount < retryBackoffMs.length
      ) {
        await sleep(retryBackoffMs[retryCount], input.signal);
        retryCount += 1;
        continue;
      }
      if (isProxyNetworkFailure) {
        throw networkFailure(body, retryCount);
      }
      return {
        statusCode: response.status,
        body,
        contentType: response.headers.get('Content-Type') ?? undefined,
        retryCount,
      };
    } catch (error) {
      if (isAbortError(error)) throw error;
      if (!isRetryableNetworkError(error) || retryCount >= retryBackoffMs.length) {
        if ((error as NetworkFailure).retryCount !== undefined) throw error;
        throw networkFailure(describeNetworkError(error), retryCount);
      }
      await sleep(retryBackoffMs[retryCount], input.signal);
      retryCount += 1;
    }
  }
}

async function fetchProbeFollowingSameOriginRedirects(
  requestURL: string,
  init: RequestInit,
  securityMode: RelayConnectionSecurityMode = 'remote_https',
): Promise<Response> {
  // Public Relay requests go through the server proxy, which owns SSRF validation and redirects.
  if (requestURL.startsWith('/')) return fetchRelayProbeRequest(requestURL, init);

  const original = new URL(requestURL);
  let current = original;
  for (let redirectCount = 0; redirectCount <= MAX_SAME_ORIGIN_REDIRECTS; redirectCount += 1) {
    const response = await fetchRelayProbeRequest(current.toString(), init);
    if (response.status < 300 || response.status >= 400) return response;
    const location = response.headers.get('Location');
    if (!location || redirectCount === MAX_SAME_ORIGIN_REDIRECTS) return response;

    let redirected: URL;
    try {
      redirected = new URL(location, current);
    } catch {
      return response;
    }
    if (
      redirected.origin !== original.origin
      || (securityMode === 'remote_https' && redirected.protocol !== 'https:')
      || redirected.username
      || redirected.password
    ) {
      return response;
    }
    try {
      await response.body?.cancel();
    } catch {
      // Redirect bodies are irrelevant; continue with the already validated same-origin target.
    }
    current = redirected;
  }
  throw new Error('Unreachable redirect state');
}

async function fetchRelayProbeRequest(requestURL: string, init: RequestInit): Promise<Response> {
  const parentSignal = init.signal;
  const controller = new AbortController();
  let didTimeout = false;
  const abortFromParent = () => controller.abort();
  if (parentSignal?.aborted) {
    abortFromParent();
  } else {
    parentSignal?.addEventListener('abort', abortFromParent, { once: true });
  }
  const timeout = setTimeout(() => {
    didTimeout = true;
    controller.abort();
  }, REQUEST_TIMEOUT_MS);

  try {
    return await fetchBrowserRelayDirect(requestURL, { ...init, signal: controller.signal });
  } catch (error) {
    if (didTimeout) {
      throw new DOMException(`Relay request timed out after ${REQUEST_TIMEOUT_MS}ms.`, 'TimeoutError');
    }
    throw error;
  } finally {
    clearTimeout(timeout);
    parentSignal?.removeEventListener('abort', abortFromParent);
  }
}

function isRetryableProxyNetworkFailure(body: string): boolean {
  let diagnostic = body;
  try {
    const payload = JSON.parse(body) as { error?: unknown; code?: unknown };
    diagnostic = [payload.code, payload.error]
      .filter((value): value is string => typeof value === 'string')
      .join(' ');
  } catch {
    // The proxy normally returns JSON, but classification still works for a plain diagnostic.
  }
  if (
    /certificate|cert_|ssl|tls|self[ -]?signed|unable_to_verify|altname|hostname mismatch/i
      .test(diagnostic)
  ) {
    return false;
  }
  return /timeout|request aborted|econnreset|econnrefused|enotfound|eai_again|socket hang up|connection (?:reset|refused|closed)|networkerror/i
    .test(diagnostic);
}

function generationRequest(
  apiBaseURL: string,
  transport: RelayProbeTransportKind,
  modelID: string,
  securityMode: RelayConnectionSecurityMode = 'remote_https',
): { method: 'POST'; requestURL: string; body: Record<string, unknown> } {
  switch (transport) {
    case 'openai_responses':
      return {
        method: 'POST',
        requestURL: appendRelayEndpointPath(apiBaseURL, 'responses', securityMode),
        body: {
          model: modelID,
          input: [{ role: 'user', content: [{ type: 'input_text', text: 'ping' }] }],
          max_output_tokens: 1,
          stream: false,
          store: false,
        },
      };
    case 'anthropic_messages':
      return {
        method: 'POST',
        requestURL: appendRelayEndpointPath(apiBaseURL, 'messages', securityMode),
        body: { model: modelID, max_tokens: 1, messages: [{ role: 'user', content: 'ping' }] },
      };
    case 'gemini_generate_content':
      return {
        method: 'POST',
        requestURL: appendRelayEndpointPath(
          apiBaseURL,
          `models/${encodeURIComponent(modelID)}:generateContent`,
          securityMode,
        ),
        body: {
          contents: [{ role: 'user', parts: [{ text: 'ping' }] }],
          generationConfig: { maxOutputTokens: 1 },
        },
      };
    case 'openai_chat_completions':
      return {
        method: 'POST',
        requestURL: appendRelayEndpointPath(apiBaseURL, 'chat/completions', securityMode),
        body: {
          model: modelID,
          stream: false,
          max_tokens: 1,
          messages: [{ role: 'user', content: 'ping' }],
        },
      };
  }
}

function parseCatalogModelIDs(body: string, transport: RelayProbeTransportKind): string[] | null {
  let payload: unknown;
  try {
    payload = JSON.parse(body);
  } catch {
    return null;
  }
  if (!payload || (typeof payload !== 'object' && !Array.isArray(payload))) return null;

  let entries: unknown[] | null = null;
  if (Array.isArray(payload)) {
    entries = payload;
  } else {
    const object = payload as Record<string, unknown>;
    if (Array.isArray(object.data)) entries = object.data;
    else if (Array.isArray(object.models)) entries = object.models;
  }
  if (!entries) return null;

  const seen = new Set<string>();
  const modelIDs: string[] = [];
  for (const entry of entries) {
    const object = entry && typeof entry === 'object' ? entry as Record<string, unknown> : undefined;
    const raw = typeof entry === 'string'
      ? entry
      : typeof object?.id === 'string'
        ? object.id
        : typeof object?.name === 'string'
          ? object.name
          : '';
    const modelID = (transport === 'gemini_generate_content' ? raw.replace(/^models\//, '') : raw).trim();
    if (!modelID || seen.has(modelID)) continue;
    seen.add(modelID);
    modelIDs.push(modelID);
  }
  return modelIDs;
}

function buildRelayCatalogModel(modelID: string, transport: RelayProbeTransportKind): AIModel {
  return buildCatalogModel({
    providerKind: transport === 'anthropic_messages'
      ? 'anthropic'
      : transport === 'gemini_generate_content'
        ? 'gemini'
        : 'openAI',
    runtimeModelId: modelID,
    fallbackName: modelID,
  });
}

function transportOrder(
  explicitTransport: RelayProbeTransportKind | undefined,
  explicitVersion: string | undefined,
  modelHint: string | undefined,
  apiKey: string,
): RelayProbeTransportKind[] {
  if (explicitTransport) return [explicitTransport];
  const hint = modelHint?.toLowerCase() ?? '';
  const key = apiKey.toLowerCase();
  if (explicitVersion === 'v1beta' || hint.includes('gemini') || key.startsWith('aiza')) {
    return ['gemini_generate_content', 'openai_chat_completions', 'anthropic_messages'];
  }
  if (hint.includes('claude') || key.startsWith('sk-ant-')) {
    return ['anthropic_messages', 'openai_chat_completions', 'gemini_generate_content'];
  }
  return ['openai_chat_completions', 'anthropic_messages', 'gemini_generate_content'];
}

function generationTransportOrder(
  explicitTransport: RelayProbeTransportKind | undefined,
  explicitVersion: string | undefined,
  modelHint: string | undefined,
  apiKey: string,
): RelayProbeTransportKind[] {
  if (explicitTransport) return [explicitTransport];
  const catalogOrder = transportOrder(undefined, explicitVersion, modelHint, apiKey);
  const result: RelayProbeTransportKind[] = [];
  for (const transport of catalogOrder) {
    result.push(transport);
    if (transport === 'openai_chat_completions') result.push('openai_responses');
  }
  return result;
}

function defaultAuthMode(
  transport: RelayProbeTransportKind,
): Exclude<RelayAuthMode, 'auto' | 'query_key'> {
  if (transport === 'anthropic_messages') return 'x_api_key';
  if (transport === 'gemini_generate_content') return 'x_goog_api_key';
  return 'bearer';
}

function classifyStatus(status: number): RelayDiscoveryFailureKind {
  if (status === 401 || status === 403) return 'authentication_rejected';
  if (status === 404 || status === 405) return 'route_unavailable';
  if (status === 429) return 'rate_limited';
  if (status >= 500) return 'temporary_failure';
  return 'invalid_response';
}

function isBlockingFailure(failure: RelayDiscoveryFailureKind): boolean {
  return failure === 'authentication_rejected'
    || failure === 'rate_limited'
    || failure === 'temporary_failure'
    || failure === 'network';
}

function is2xx(status: number): boolean {
  return status >= 200 && status < 300;
}

export { isRelayGenerationSuccessResponse };

function extractDiagnostic(body: string, input: RelayDiscoveryInput): string | undefined {
  return extractErrorSnippet(body, 1_000, relaySensitiveCredentialValues({
    apiKey: input.apiKey,
    headers: input.headers,
    queryParams: input.queryParams,
  }));
}

function finishDetected(
  attempts: RelayDiscoveryAttempt[],
  detection: RelayDetectedConfiguration,
): RelayDiscoveryResult {
  return {
    state: detection.generationVerified ? 'verified' : 'needs_manual_model',
    detection,
    attempts,
    diagnostic: preferredDiagnostic(attempts),
    retriedRequestCount: totalRetries(attempts),
  };
}

function finishFailed(
  attempts: RelayDiscoveryAttempt[],
  failure: RelayDiscoveryFailureKind,
): RelayDiscoveryResult {
  return {
    state: 'failed',
    attempts,
    failure,
    diagnostic: preferredDiagnostic(attempts),
    retriedRequestCount: totalRetries(attempts),
  };
}

function failed(failure: RelayDiscoveryFailureKind): RelayDiscoveryResult {
  return { state: 'failed', attempts: [], failure, retriedRequestCount: 0 };
}

function preferredDiagnostic(attempts: RelayDiscoveryAttempt[]): string | undefined {
  const preferred = [...attempts].reverse().find(
    (attempt) => (attempt.statusCode === 400 || attempt.statusCode === 422) && attempt.upstreamMessage,
  );
  return preferred?.upstreamMessage
    ?? [...attempts].reverse().find((attempt) => attempt.upstreamMessage)?.upstreamMessage;
}

function totalRetries(attempts: RelayDiscoveryAttempt[]): number {
  return attempts.reduce((total, attempt) => total + attempt.retryCount, 0);
}

function networkFailure(message: string, retryCount: number): NetworkFailure {
  const error = new Error(message) as NetworkFailure;
  error.retryCount = retryCount;
  return error;
}

function isRetryableNetworkError(error: unknown): boolean {
  if (error instanceof TypeError) return /failed to fetch|fetch failed|networkerror|load failed/i.test(error.message);
  if (error instanceof DOMException) {
    return error.name === 'TimeoutError' || error.name === 'NetworkError';
  }
  return false;
}

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError';
}

function describeNetworkError(error: unknown): string {
  if (error instanceof Error) return `${error.message} (${error.name})`;
  return String(error);
}

function abortableSleep(durationMs: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', abort);
      resolve();
    }, durationMs);
    const abort = () => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', abort);
      reject(new DOMException('The operation was aborted.', 'AbortError'));
    };
    if (signal?.aborted) {
      abort();
      return;
    }
    signal?.addEventListener('abort', abort, { once: true });
  });
}
