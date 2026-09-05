import {
  LOCAL_ENGINE_TEMPLATES,
  classifyLocalEngineResponse,
  classifyRelayEndpoint,
  localModelLocality,
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
  }>;
  apiBaseURL?: string;
  generationVerified: boolean;
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
    // cannot satisfy this chat connection, so never expose them as selectable chat models.
    const rows = input.engine === 'lmstudio'
      ? rawRows.filter((model) => model.type === undefined || String(model.type).toLowerCase() === 'llm')
      : rawRows;
    const modelIDs = uniqueNonEmpty(rows
      .map((model) => String(input.engine === 'ollama' ? model.name ?? '' : model.id ?? model.name ?? ''))
      .filter(Boolean));
    const models = modelIDs.map((id) => {
      const row = rows.find((item) => String(
        input.engine === 'ollama' ? item.name ?? '' : item.id ?? item.name ?? '',
      ) === id);
      const state = String(row?.state ?? '').toLowerCase();
      const localLoadState: LocalBrowserConnectionResult['models'][number]['localLoadState'] =
        state === 'loaded' || state === 'loading' || state === 'unloaded'
          ? state
          : input.engine === 'vllm' || input.engine === 'openwebui' ? 'loaded' : 'unknown';
      return {
        id,
        localLoadState,
        executionLocality: localModelLocality(input.engine, id) === 'cloud'
          ? 'proxied_cloud' as const
          : 'local' as const,
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
    return {
      ...probe,
      modelIDs,
      models,
      apiBaseURL,
      generationVerified,
      failure: generationVerified ? undefined : 'invalid_response',
      state: generationVerified ? 'ready' : 'wrong_engine',
    };
  } catch (error) {
    if (input.signal?.aborted) throw error;
    return { ...probe, state: 'unreachable', failure: 'cors_blocked', modelIDs: [], models: [], generationVerified: false };
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
