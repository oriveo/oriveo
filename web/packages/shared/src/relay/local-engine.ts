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

export function localModelLocality(engine: LocalEngineKind, modelID: string): LocalModelLocality {
  return engine === 'ollama' && modelID.toLowerCase().endsWith(':cloud') ? 'cloud' : 'local';
}

function isRecord(value: unknown): value is Record<string, any> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
