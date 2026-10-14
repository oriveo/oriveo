import type { EngineDeclaration } from '../types/relay';

export type LocalEngineKind = 'llamacpp' | 'ollama' | 'lmstudio' | 'vllm' | 'openwebui';
export type LocalEngineState = 'ready' | 'loading' | 'wrong_engine' | 'parameter_rejected' | 'unreachable';
export type LocalModelLocality = 'local' | 'cloud';

export interface LocalEngineTemplate {
  engine: LocalEngineKind;
  defaultEndpoint: string;
  probe: { method: 'GET' | 'POST'; path: string };
  catalogPath: string;
  introspection: { method: 'GET' | 'POST'; path: string };
  generationPaths: string[];
}

export const LOCAL_ENGINE_TEMPLATES: Record<LocalEngineKind, LocalEngineTemplate> = {
  llamacpp: { engine: 'llamacpp', defaultEndpoint: 'http://127.0.0.1:8080', probe: { method: 'GET', path: '/health' }, catalogPath: '/v1/models', introspection: { method: 'GET', path: '/props' }, generationPaths: ['/v1/chat/completions', '/v1/messages', '/completion'] },
  ollama: { engine: 'ollama', defaultEndpoint: 'http://127.0.0.1:11434', probe: { method: 'GET', path: '/api/tags' }, catalogPath: '/api/tags', introspection: { method: 'POST', path: '/api/show' }, generationPaths: ['/api/chat', '/v1/chat/completions'] },
  // All three LM Studio metadata paths have to use /api/v0/models: classify keys off
  // data[].state, which is the only shape that tells it apart from vLLM. The
  // OpenAI-compatible /v1/models has no state and /api/v1/models uses the newer models[]
  // shape, so either one makes a real LM Studio look like wrong_engine.
  lmstudio: { engine: 'lmstudio', defaultEndpoint: 'http://127.0.0.1:1234', probe: { method: 'GET', path: '/api/v0/models' }, catalogPath: '/api/v0/models', introspection: { method: 'GET', path: '/api/v0/models' }, generationPaths: ['/v1/chat/completions', '/v1/responses'] },
  vllm: { engine: 'vllm', defaultEndpoint: 'http://127.0.0.1:8000', probe: { method: 'GET', path: '/v1/models' }, catalogPath: '/v1/models', introspection: { method: 'GET', path: '/health' }, generationPaths: ['/v1/chat/completions', '/v1/responses'] },
  openwebui: { engine: 'openwebui', defaultEndpoint: 'https://127.0.0.1:3000', probe: { method: 'GET', path: '/api/models' }, catalogPath: '/api/models', introspection: { method: 'GET', path: '/api/models' }, generationPaths: ['/api/chat/completions'] },
};

export function classifyLocalEngineResponse(
  engine: LocalEngineKind,
  status: number,
  contentType: string,
  body: unknown,
): LocalEngineState {
  if (status === 400 && isRecord(body) && isRecord(body.error) && body.error.type === 'invalid_request_error') return 'parameter_rejected';
  if (status === 503) return 'loading';
  if (status < 200 || status >= 300 || !contentType.toLowerCase().includes('json') || !isRecord(body)) return 'wrong_engine';
  if (engine === 'llamacpp') return body.status === 'ok' ? 'ready' : body.status === 'loading model' ? 'loading' : 'wrong_engine';
  if (engine === 'ollama') return Array.isArray(body.models) ? 'ready' : 'wrong_engine';
  if (engine === 'openwebui') {
    const rows = Array.isArray(body.data) ? body.data : Array.isArray(body.models) ? body.models : null;
    return rows?.every((item) => isRecord(item) && (typeof item.id === 'string' || typeof item.name === 'string'))
      ? 'ready'
      : 'wrong_engine';
  }
  if (!Array.isArray(body.data)) return 'wrong_engine';
  if (engine === 'lmstudio') return body.data.some((item) => isRecord(item) && typeof item.state === 'string') ? 'ready' : 'wrong_engine';
  return body.data.every((item) => isRecord(item) && typeof item.id === 'string' && item.state === undefined) ? 'ready' : 'wrong_engine';
}

/* -- Fingerprint (RL2-ENGINE-01) ------------------------- */

/** The five read-only GETs always sent for fingerprinting; the criteria look only at the shape of a 2xx JSON object, the status code alone does not decide. */
export const LOCAL_ENGINE_FINGERPRINT_PATHS = ['/props', '/api/tags', '/api/v0/models', '/version', '/v1/models'] as const;
export type LocalEngineFingerprintPath = typeof LOCAL_ENGINE_FINGERPRINT_PATHS[number];

/** Result of one fingerprint GET; `body` is the parsed JSON (unparseable = `undefined`), and a network-layer failure drops the whole entry. */
export interface LocalEngineFingerprintResponse {
  status: number;
  body: unknown;
}

/** Fingerprint verdict. The channel is the connection-level default (wire value); `generic` carries no engineProfile. */
export type LocalEngineFingerprint =
  | { outcome: 'engine'; engineProfile: LocalEngineKind; channel: 'openai_chat_completions' }
  | { outcome: 'generic'; channel: 'openai_chat_completions' }
  | { outcome: 'manual' };

/**
 * Exactly one engine matches -> that engine; two or more -> manual; none -> generic if `/v1/models` matches, otherwise manual.
 * LM Studio answers unknown paths with 200 + `{error}`, so every rule requires a specific shape.
 */
export function classifyLocalEngineFingerprint(
  responses: Partial<Record<LocalEngineFingerprintPath, LocalEngineFingerprintResponse>>,
): LocalEngineFingerprint {
  const json = (path: LocalEngineFingerprintPath): Record<string, any> | undefined => {
    const response = responses[path];
    return response && response.status >= 200 && response.status < 300 && isRecord(response.body)
      ? response.body
      : undefined;
  };
  const props = json('/props');
  const tags = json('/api/tags');
  const v0 = json('/api/v0/models');
  const version = json('/version');
  const hits: LocalEngineKind[] = [];
  if (props && (isRecord(props.modalities) || isRecord(props.default_generation_settings))) hits.push('llamacpp');
  if (tags && Array.isArray(tags.models) && tags.models.every((row: unknown) => isRecord(row) && typeof row.name === 'string')) hits.push('ollama');
  if (v0 && Array.isArray(v0.data) && v0.data.every((row: unknown) => isRecord(row) && typeof row.type === 'string')) hits.push('lmstudio');
  if (version && typeof version.version === 'string' && !('error' in version)) hits.push('vllm');
  if (hits.length === 1) return { outcome: 'engine', engineProfile: hits[0]!, channel: 'openai_chat_completions' };
  if (hits.length > 1) return { outcome: 'manual' };
  const models = json('/v1/models');
  return models && Array.isArray(models.data) ? { outcome: 'generic', channel: 'openai_chat_completions' } : { outcome: 'manual' };
}

/* -- Per-model capability declaration (RL2-ENGINE-02) ----- */

/** Whether a catalog row can enter the chat catalog: only LM Studio's embeddings rows cannot (vlm can). */
export function isLocalEngineChatCatalogRow(engine: LocalEngineKind, row: Record<string, unknown>): boolean {
  return engine !== 'lmstudio' || String(row.type ?? '').toLowerCase() !== 'embeddings';
}

/**
 * Read a model's declaration from the responses the connector already requests, without sending extra requests.
 * - Ollama: `capabilities` of the `/api/tags` row (vision / tools / thinking; a missing word = false; a missing key = all unknown);
 * - LM Studio: `type` (vlm / llm) and `capabilities` (tool_use) of the `/api/v0/models` row; thinking unknown;
 * - llama.cpp: the single `/props` applies to every model of the connection: `modalities.vision`, and `supports_tools` counts as a declaration only when true;
 * - vLLM / Open WebUI: declare nothing.
 * Unknown is always a missing key; an empty object means no declaration at all.
 */
export function localEngineModelDeclaration(
  engine: LocalEngineKind,
  row: Record<string, unknown>,
  props: unknown,
): EngineDeclaration {
  if (engine === 'ollama') {
    if (!Array.isArray(row.capabilities)) return {};
    const words = row.capabilities;
    return { image: words.includes('vision'), toolCall: words.includes('tools'), thinking: words.includes('thinking') };
  }
  if (engine === 'lmstudio') {
    const declaration: EngineDeclaration = {};
    const type = typeof row.type === 'string' ? row.type.toLowerCase() : undefined;
    if (type === 'vlm') declaration.image = true;
    else if (type === 'llm') declaration.image = false;
    if (Array.isArray(row.capabilities)) declaration.toolCall = row.capabilities.includes('tool_use');
    return declaration;
  }
  if (engine === 'llamacpp') {
    const declaration: EngineDeclaration = {};
    if (!isRecord(props)) return declaration;
    if (isRecord(props.modalities) && typeof props.modalities.vision === 'boolean') declaration.image = props.modalities.vision;
    if (isRecord(props.chat_template_caps) && props.chat_template_caps.supports_tools === true) declaration.toolCall = true;
    return declaration;
  }
  return {};
}

export function localModelLocality(engine: LocalEngineKind, modelID: string): LocalModelLocality {
  return engine === 'ollama' && modelID.toLowerCase().endsWith(':cloud') ? 'cloud' : 'local';
}

function isRecord(value: unknown): value is Record<string, any> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
