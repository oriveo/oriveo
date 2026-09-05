/* ── Gemini GenerateContent API types ─────────────────── */

/** Generate content request */
export interface GeminiGenerateRequest {
  contents: GeminiContent[];
  generationConfig?: GeminiGenerationConfig;
}

export interface GeminiContent {
  role: 'user' | 'model';
  parts: GeminiPart[];
}

export type GeminiPart =
  | { text: string }
  | { inlineData: GeminiInlineData };

export interface GeminiInlineData {
  mimeType: string;
  data: string;
}

export interface GeminiGenerationConfig {
  thinkingConfig?: { thinkingBudget: number };
  responseModalities?: string[];
}

/** GET /models response */
export interface GeminiModelsResponse {
  models: GeminiRemoteModel[];
  nextPageToken?: string;
}

export interface GeminiRemoteModel {
  name: string;
  displayName: string;
  description?: string;
  supportedGenerationMethods?: string[];
  inputTokenLimit?: number;
  outputTokenLimit?: number;
  /** Thinking capability flag returned by the Gemini API. */
  thinking?: boolean;
}

/** SSE chunk from streaming generate content */
export interface GeminiStreamChunk {
  candidates?: {
    content?: {
      parts?: { text?: string; inlineData?: GeminiInlineData }[];
      role?: string;
    };
    finishReason?: string;
  }[];
  usageMetadata?: GeminiUsage;
}

export interface GeminiUsage {
  promptTokenCount?: number;
  candidatesTokenCount?: number;
  totalTokenCount?: number;
}
