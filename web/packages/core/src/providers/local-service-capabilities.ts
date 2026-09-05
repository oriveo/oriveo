export type LocalServiceCapability = 'embedding' | 'rerank';

export interface LocalServiceCapabilityContract {
  capability: LocalServiceCapability;
  candidatePaths: string[];
  /** Candidate paths never mean supported; runtime/introspection evidence is required before use. */
  support: 'unknown' | 'supported' | 'unsupported';
  source: 'engine_introspection' | 'runtime_rejected' | 'user_declared' | 'unknown';
}

export const LOCAL_SERVICE_CAPABILITY_PATHS: Record<string, Partial<Record<LocalServiceCapability, string[]>>> = {
  llamacpp: { embedding: ['/embedding', '/v1/embeddings'], rerank: ['/rerank', '/v1/rerank'] },
  ollama: { embedding: ['/api/embed', '/api/embeddings'] },
  lmstudio: { embedding: ['/v1/embeddings'] },
  vllm: { embedding: ['/v1/embeddings'], rerank: ['/rerank', '/v1/rerank'] },
  openwebui: { embedding: ['/api/embeddings'] },
};
