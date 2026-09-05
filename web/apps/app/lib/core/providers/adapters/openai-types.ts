/* ── OpenAI API types ─────────────────────────────────── */

/** Chat completion request */
export interface OpenAIChatRequest {
  model: string;
  stream?: boolean;
  stream_options?: { include_usage: boolean };
  messages: OpenAIMessage[];
  reasoning_effort?: 'low' | 'medium' | 'high';
}

export interface OpenAIMessage {
  role: 'user' | 'assistant' | 'system';
  content: string | OpenAIContentPart[];
}

export type OpenAIContentPart =
  | { type: 'text'; text: string }
  | { type: 'image_url'; image_url: { url: string } }
  | { type: 'video_url'; video_url: { url: string } };

/** GET /models response */
export interface OpenAIModelsResponse {
  data: OpenAIRemoteModel[];
}

export interface OpenAIRemoteModel {
  id: string;
  object: string;
  created: number;
  owned_by: string;
}

/** Content part in image generation response */
export interface OpenAIImagePart {
  type: string;
  image_url?: { url: string };
}

/** SSE chunk from streaming chat completions */
export interface OpenAIStreamChunk {
  id?: string;
  model?: string;
  choices?: {
    index: number;
    delta?: { role?: string; content?: string; images?: OpenAIImagePart[] };
    finish_reason?: string | null;
  }[];
  usage?: OpenAIUsage;
}

export interface OpenAIUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
}
