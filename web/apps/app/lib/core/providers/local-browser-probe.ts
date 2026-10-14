import {
  LOCAL_ENGINE_FINGERPRINT_PATHS,
  LOCAL_ENGINE_TEMPLATES,
  classifyLocalEngineFingerprint,
  classifyLocalEngineResponse,
  classifyRelayCleartextAddress,
  classifyRelayEndpoint,
  isLocalEngineChatCatalogRow,
  localEngineModelDeclaration,
  localModelLocality,
  type EngineDeclaration,
  type LocalEngineFingerprint,
  type LocalEngineFingerprintPath,
  type LocalEngineFingerprintResponse,
  type LocalEngineKind,
  type LocalEngineState,
  type RelayConnectionSecurityMode,
} from '@oriveo/shared';
import { sendMessageStream } from './adapters/relay';

export type LocalBrowserProbeFailure = 'unsupported_browser' | 'permission_denied' | 'cors_blocked' | 'unsafe_address' | 'redirect_blocked' | 'invalid_response' | 'credential_required' | 'authentication_rejected' | 'cleartext_credentials';

export interface LocalBrowserProbeResult {
  state: LocalEngineState;
  failure?: LocalBrowserProbeFailure;
  endpoint: string;
  statusCode?: number;
}

export interface LocalBrowserConnectionResult extends LocalBrowserProbeResult {
  modelIDs: string[];
  models: Array<{
    id: string;
    localLoadState: 'loaded' | 'loading' | 'unloaded' | 'unknown';
    executionLocality: 'local' | 'proxied_cloud' | 'unknown';
    /** Capabilities the engine declares for this model; omit this key when there are none. */
    engineDeclaration?: EngineDeclaration;
  }>;
  apiBaseURL?: string;
  generationVerified: boolean;
  /** Only take responses already received while connecting: n_ctx from llama.cpp `/props`, max_context_length from the LM Studio default model catalog row. */
  contextLength?: number;
}

/**
 * Addresses the Web local page can connect to: any https; http only loopback (127.0.0.1 / localhost / [::1]),
 * other http is blocked by the browser as mixed content, so show an explanation row instead of proxying. The loopback check reuses the shared address classifier.
 */
export type LocalBrowserEndpointAccess =
  | { kind: 'empty' }
  | { kind: 'invalid' }
  | { kind: 'lan_http_blocked' }
  | { kind: 'allowed'; securityMode: Extract<RelayConnectionSecurityMode, 'remote_https' | 'local_http'>; normalized: string };

export function localBrowserEndpointAccess(raw: string): LocalBrowserEndpointAccess {
  const trimmed = raw.trim();
  if (!trimmed) return { kind: 'empty' };
  const https = classifyRelayEndpoint({ raw: trimmed, securityMode: 'remote_https' });
  if (https.allowed && https.normalized) return { kind: 'allowed', securityMode: 'remote_https', normalized: https.normalized };
  if (https.reason !== 'cleartext_not_allowed') return { kind: 'invalid' };
  const address = classifyRelayCleartextAddress({ raw: trimmed, securityMode: 'local_http' });
  if (!address.allowed || address.reason !== 'loopback') return { kind: 'lan_http_blocked' };
  const loopback = classifyRelayEndpoint({ raw: trimmed, securityMode: 'local_http' });
  return loopback.allowed && loopback.normalized
    ? { kind: 'allowed', securityMode: 'local_http', normalized: loopback.normalized }
    : { kind: 'invalid' };
}

/** Browser-only local probe. This function intentionally has no server-proxy fallback. */
export async function probeLocalEngineInBrowser(input: {
  engine: LocalEngineKind;
  endpoint: string;
  securityMode: Exclude<RelayConnectionSecurityMode, 'tofu_https'>;
  apiKey?: string;
  signal?: AbortSignal;
}): Promise<LocalBrowserProbeResult> {
  const apiKey = input.apiKey?.trim() ?? '';
  if (input.engine === 'openwebui' && !apiKey) {
    return { state: 'unreachable', failure: 'credential_required', endpoint: input.endpoint };
  }
  const classification = classifyRelayEndpoint({
    raw: input.endpoint,
    securityMode: input.securityMode,
    credentials: input.engine === 'openwebui'
      ? { authMode: 'bearer', hasKey: Boolean(apiKey) }
      : { authMode: 'none', hasKey: false },
  });
  if (!classification.allowed || !classification.normalized) {
    return {
      state: 'unreachable',
      failure: classification.reason === 'cleartext_credentials' ? 'cleartext_credentials' : 'unsafe_address',
      endpoint: input.endpoint,
    };
  }
  if (typeof window === 'undefined' || typeof fetch !== 'function') return { state: 'unreachable', failure: 'unsupported_browser', endpoint: classification.normalized };

  const permission = await localNetworkPermission();
  if (permission === 'denied') return { state: 'unreachable', failure: 'permission_denied', endpoint: classification.normalized };
  const template = LOCAL_ENGINE_TEMPLATES[input.engine];
  const requestURL = new URL(template.probe.path, `${classification.normalized.replace(/\/$/, '')}/`).toString();
  try {
    const response = await fetch(requestURL, {
      method: template.probe.method,
      mode: 'cors',
      redirect: 'manual',
      credentials: 'omit',
      headers: localEngineHeaders(input.engine, apiKey),
      referrerPolicy: 'no-referrer',
      signal: input.signal,
    });
    if (response.type === 'opaqueredirect' || (response.status >= 300 && response.status < 400)) return { state: 'unreachable', failure: 'redirect_blocked', endpoint: classification.normalized, statusCode: response.status };
    if (response.status === 401 || response.status === 403) return { state: 'unreachable', failure: 'authentication_rejected', endpoint: classification.normalized, statusCode: response.status };
    const contentType = response.headers.get('content-type') ?? '';
    const body = contentType.toLowerCase().includes('json') ? await response.json() : await response.text();
    const state = classifyLocalEngineResponse(input.engine, response.status, contentType, body);
    return { state, failure: state === 'wrong_engine' ? 'invalid_response' : undefined, endpoint: classification.normalized, statusCode: response.status };
  } catch (error) {
    if (input.signal?.aborted) throw error;
    return { state: 'unreachable', failure: 'cors_blocked', endpoint: classification.normalized };
  }
}

async function localNetworkPermission(): Promise<PermissionState | 'unsupported'> {
  if (!navigator.permissions?.query) return 'unsupported';
  try {
    const result = await navigator.permissions.query({ name: 'local-network-access' as PermissionName });
    return result.state;
  } catch {
    return 'unsupported';
  }
}

export async function connectLocalEngineInBrowser(input: {
  engine: LocalEngineKind;
  endpoint: string;
  securityMode: Exclude<RelayConnectionSecurityMode, 'tofu_https'>;
  modelHint?: string;
  apiKey?: string;
  signal?: AbortSignal;
}): Promise<LocalBrowserConnectionResult> {
  const probe = await probeLocalEngineInBrowser(input);
  if (probe.state !== 'ready') return { ...probe, modelIDs: [], models: [], generationVerified: false };

  try {
    const template = LOCAL_ENGINE_TEMPLATES[input.engine];
    const catalogResponse = await localFetch(new URL(template.catalogPath, `${probe.endpoint.replace(/\/$/, '')}/`).toString(), {
      method: 'GET',
      headers: localEngineHeaders(input.engine, input.apiKey),
      signal: input.signal,
    });
    const catalogFailure = responseFailure(catalogResponse);
    if (catalogFailure) {
      return { ...probe, state: 'unreachable', failure: catalogFailure, statusCode: catalogResponse.status, modelIDs: [], models: [], generationVerified: false };
    }
    const catalog = await catalogResponse.json() as Record<string, unknown>;
    const rawRows = input.engine === 'ollama'
      ? arrayRecords(catalog.models)
      : input.engine === 'openwebui'
        ? [...arrayRecords(catalog.data), ...arrayRecords(catalog.models)]
        : arrayRecords(catalog.data);
    // LM Studio's v0 catalog also contains embedding models. They are valid catalog rows but
    // cannot satisfy this chat connection, so never expose them as selectable chat models
    // (vlm rows are chat models and stay).
    const rows = rawRows.filter((model) => isLocalEngineChatCatalogRow(input.engine, model));
    const modelIDs = uniqueNonEmpty(rows
      .map((model) => String(input.engine === 'ollama' ? model.name ?? '' : model.id ?? model.name ?? ''))
      .filter(Boolean));
    const catalogModels = modelIDs.map((id) => {
      const row = rows.find((item) => String(
        input.engine === 'ollama' ? item.name ?? '' : item.id ?? item.name ?? '',
      ) === id);
      const state = String(row?.state ?? '').toLowerCase();
      const localLoadState: LocalBrowserConnectionResult['models'][number]['localLoadState'] =
        state === 'loaded' || state === 'loading' || state === 'unloaded'
          ? state
          : input.engine === 'vllm' || input.engine === 'openwebui' ? 'loaded' : 'unknown';
      return {
        row,
        model: {
          id,
          localLoadState,
          executionLocality: localModelLocality(input.engine, id) === 'cloud'
            ? 'proxied_cloud' as const
            : 'local' as const,
        },
      };
    });
    if (!catalogResponse.ok || modelIDs.length === 0) {
      return { ...probe, state: 'wrong_engine', failure: 'invalid_response', modelIDs: [], models: [], generationVerified: false };
    }

    const modelID = input.modelHint?.trim() || modelIDs[0];
    const introspectionResponse = await localFetch(
      new URL(template.introspection.path, `${probe.endpoint.replace(/\/$/, '')}/`).toString(),
      {
        method: template.introspection.method,
        headers: localEngineHeaders(input.engine, input.apiKey),
        signal: input.signal,
        ...(input.engine === 'ollama' ? {
          // Ollama accepts a JSON string without an explicit Content-Type. Keeping this request
          // CORS-safelisted avoids an otherwise unnecessary browser preflight that stock Ollama
          // cannot satisfy on Local Network Access connections.
          body: JSON.stringify({ model: modelID }),
        } : {}),
      },
    );
    const introspectionFailure = responseFailure(introspectionResponse);
    if (introspectionFailure) {
      return { ...probe, state: 'unreachable', failure: introspectionFailure, statusCode: introspectionResponse.status, modelIDs: [], models: [], generationVerified: false };
    }
    const introspectionBody = input.engine === 'vllm'
      ? undefined
      : await introspectionResponse.json().catch(() => undefined) as Record<string, unknown> | undefined;
    if (!introspectionMatches(input.engine, introspectionResponse.status, introspectionBody)) {
      return { ...probe, state: 'wrong_engine', failure: 'invalid_response', modelIDs: [], models: [], generationVerified: false };
    }
    // Declarations only read responses that were requested anyway: Ollama / LM Studio are catalog rows, llama.cpp is /props (introspection).
    const models: LocalBrowserConnectionResult['models'] = catalogModels.map(({ row, model }) => {
      const declaration = localEngineModelDeclaration(
        input.engine,
        row ?? {},
        input.engine === 'llamacpp' ? introspectionBody : undefined,
      );
      return Object.keys(declaration).length > 0 ? { ...model, engineDeclaration: declaration } : model;
    });
    const apiBaseURL = new URL(input.engine === 'openwebui' ? '/api' : '/v1', `${probe.endpoint.replace(/\/$/, '')}/`).toString().replace(/\/$/, '');
    const handle = sendMessageStream(input.engine === 'openwebui' ? input.apiKey?.trim() ?? '' : '', modelID, [{ role: 'user', content: 'Reply with one token.' }], apiBaseURL, {
      relayResolvedBaseURLText: apiBaseURL,
      relayResolvedAPIBaseURLIsExact: true,
      relayTransport: 'openai_chat_completions',
      relayAuthMode: input.engine === 'openwebui' ? 'bearer' : 'none',
      relaySecurityMode: input.securityMode,
      relayStream: false,
      relayMaxOutputTokens: 1,
    });
    const abort = () => handle.abort();
    input.signal?.addEventListener('abort', abort, { once: true });
    const reader = handle.stream.getReader();
    let generationVerified = false;
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        generationVerified = true;
      }
    } finally {
      input.signal?.removeEventListener('abort', abort);
      reader.releaseLock();
    }
    const contextLength = localEngineContextLength(
      input.engine,
      introspectionBody,
      catalogModels.find((item) => item.model.id === modelID)?.row,
    );
    return {
      ...probe,
      modelIDs,
      models,
      apiBaseURL,
      generationVerified,
      ...(contextLength ? { contextLength } : {}),
      failure: generationVerified ? undefined : 'invalid_response',
      state: generationVerified ? 'ready' : 'wrong_engine',
    };
  } catch (error) {
    if (input.signal?.aborted) throw error;
    return { ...probe, state: 'unreachable', failure: 'cors_blocked', modelIDs: [], models: [], generationVerified: false };
  }
}

/**
 * Local engine fingerprint (RL2-ENGINE-01): send five read-only GETs to the endpoint concurrently and give engine / generic / manual by the shared criteria.
 * The browser side has no TOFU certificate channel, so only the same two securityMode values as the connector are accepted; an unsafe address, a denied local-network
 * permission or all requests failing all land on manual (let the user choose by hand), without throwing.
 */
export async function fingerprintLocalEngineInBrowser(input: {
  endpoint: string;
  securityMode: Exclude<RelayConnectionSecurityMode, 'tofu_https'>;
  signal?: AbortSignal;
}): Promise<LocalEngineFingerprint> {
  const classification = classifyRelayEndpoint({
    raw: input.endpoint,
    securityMode: input.securityMode,
    credentials: { authMode: 'none', hasKey: false },
  });
  if (!classification.allowed || !classification.normalized) return { outcome: 'manual' };
  if (typeof window === 'undefined' || typeof fetch !== 'function') return { outcome: 'manual' };
  if (await localNetworkPermission() === 'denied') return { outcome: 'manual' };
  const base = `${classification.normalized.replace(/\/$/, '')}/`;
  const entries = await Promise.all(LOCAL_ENGINE_FINGERPRINT_PATHS.map(async (path) => {
    try {
      const response = await localFetch(new URL(path, base).toString(), {
        method: 'GET',
        mode: 'cors',
        signal: input.signal,
      });
      if (response.type === 'opaqueredirect') return undefined;
      const text = await response.text();
      let body: unknown;
      try {
        body = JSON.parse(text);
      } catch {
        body = undefined;
      }
      return [path, { status: response.status, body }] as const;
    } catch (error) {
      if (input.signal?.aborted) throw error;
      return undefined;
    }
  }));
  const responses: Partial<Record<LocalEngineFingerprintPath, LocalEngineFingerprintResponse>> = {};
  for (const entry of entries) {
    if (entry) responses[entry[0]] = entry[1];
  }
  return classifyLocalEngineFingerprint(responses);
}

/**
 * Read-only declaration reading for re-detection: sends only GET (liveness, catalog, llama.cpp /props),
 * no generation request and no Ollama /api/show, since ping would make the engine load the model. If any step fails, returns an empty list and the caller keeps the old declarations.
 */
export async function inspectLocalEngineDeclarationsInBrowser(input: {
  engine: LocalEngineKind;
  endpoint: string;
  securityMode: Exclude<RelayConnectionSecurityMode, 'tofu_https'>;
  apiKey?: string;
  signal?: AbortSignal;
}): Promise<Array<{ id: string; engineDeclaration?: EngineDeclaration }>> {
  const probe = await probeLocalEngineInBrowser(input);
  if (probe.state !== 'ready') return [];
  try {
    const template = LOCAL_ENGINE_TEMPLATES[input.engine];
    const root = `${probe.endpoint.replace(/\/$/, '')}/`;
    const headers = localEngineHeaders(input.engine, input.apiKey);
    const catalogResponse = await localFetch(new URL(template.catalogPath, root).toString(), { method: 'GET', headers, signal: input.signal });
    if (responseFailure(catalogResponse) || !catalogResponse.ok) return [];
    const catalog = await catalogResponse.json() as Record<string, unknown>;
    const rawRows = input.engine === 'ollama'
      ? arrayRecords(catalog.models)
      : input.engine === 'openwebui'
        ? [...arrayRecords(catalog.data), ...arrayRecords(catalog.models)]
        : arrayRecords(catalog.data);
    const rows = rawRows.filter((model) => isLocalEngineChatCatalogRow(input.engine, model));
    let props: Record<string, unknown> | undefined;
    if (input.engine === 'llamacpp') {
      const propsResponse = await localFetch(new URL(template.introspection.path, root).toString(), { method: 'GET', headers, signal: input.signal });
      if (responseFailure(propsResponse) || !propsResponse.ok) return [];
      props = await propsResponse.json().catch(() => undefined) as Record<string, unknown> | undefined;
    }
    const ids = uniqueNonEmpty(rows
      .map((model) => String(input.engine === 'ollama' ? model.name ?? '' : model.id ?? model.name ?? ''))
      .filter(Boolean));
    return ids.map((id) => {
      const row = rows.find((item) => String(input.engine === 'ollama' ? item.name ?? '' : item.id ?? item.name ?? '') === id);
      const declaration = localEngineModelDeclaration(input.engine, row ?? {}, props);
      return Object.keys(declaration).length > 0 ? { id, engineDeclaration: declaration } : { id };
    });
  } catch (error) {
    if (input.signal?.aborted) throw error;
    return [];
  }
}

async function localFetch(url: string, init: RequestInit): Promise<Response> {
  return fetch(url, {
    ...init,
    credentials: 'omit',
    redirect: 'manual',
    referrerPolicy: 'no-referrer',
  });
}

function localEngineContextLength(
  engine: LocalEngineKind,
  props: Record<string, unknown> | undefined,
  defaultRow: Record<string, unknown> | undefined,
): number | undefined {
  const positive = (value: unknown) => typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : undefined;
  if (engine === 'llamacpp') {
    const settings = props?.default_generation_settings;
    return positive(props?.n_ctx)
      ?? (typeof settings === 'object' && settings !== null ? positive((settings as Record<string, unknown>).n_ctx) : undefined);
  }
  if (engine === 'lmstudio') return positive(defaultRow?.max_context_length);
  return undefined;
}

function arrayRecords(value: unknown): Array<Record<string, unknown>> {
  return Array.isArray(value)
    ? value.filter((item): item is Record<string, unknown> => typeof item === 'object' && item !== null)
    : [];
}

function uniqueNonEmpty(values: string[]): string[] {
  return [...new Set(values.map((value) => value.trim()).filter(Boolean))];
}

function responseFailure(response: Response): LocalBrowserProbeFailure | undefined {
  if (response.type === 'opaqueredirect' || (response.status >= 300 && response.status < 400)) return 'redirect_blocked';
  if (response.status === 401 || response.status === 403) return 'authentication_rejected';
  return undefined;
}

function introspectionMatches(
  engine: LocalEngineKind,
  status: number,
  body: Record<string, unknown> | undefined,
): boolean {
  if (status < 200 || status >= 300) return false;
  if (engine === 'vllm') return true;
  if (!body) return false;
  if (engine === 'llamacpp') return typeof body.default_generation_settings === 'object';
  if (engine === 'ollama') return Array.isArray(body.capabilities) || typeof body.parameters === 'string';
  return Array.isArray(body.data) || Array.isArray(body.models);
}

function localEngineHeaders(engine: LocalEngineKind, apiKey: string | undefined): Record<string, string> {
  const credential = apiKey?.trim() ?? '';
  return engine === 'openwebui' && credential
    ? { Authorization: `Bearer ${credential}` }
    : {};
}
