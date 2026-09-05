/* ── Anthropic Messages API types ─────────────────────── */

/** Messages request */
export interface AnthropicMessagesRequest {
  model: string;
  max_tokens: number;
  stream?: boolean;
  messages: AnthropicMessage[];
}

export interface AnthropicMessage {
  role: 'user' | 'assistant';
  content: string | AnthropicContentBlock[];
}

export type AnthropicContentBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; source: AnthropicImageSource }
  | { type: 'document'; source: AnthropicDocumentSource };

export interface AnthropicImageSource {
  type: 'base64';
  media_type: string;
  data: string;
}

export interface AnthropicDocumentSource {
  type: 'base64';
  media_type: 'application/pdf';
  data: string;
}

/** GET /models response */
export interface AnthropicModelsResponse {
  data: AnthropicRemoteModel[];
  has_more: boolean;
  last_id?: string;
}

export interface AnthropicRemoteModel {
  id: string;
  display_name: string;
  type: string;
  created_at: string;
  /** Structured capability fields returned by the Anthropic Models API. */
  capabilities?: AnthropicModelCapabilities;
}

/** The capabilities object from /v1/models. */
export interface AnthropicModelCapabilities {
  image_input?: { supported: boolean };
  pdf_input?: { supported: boolean };
  thinking?: {
    supported: boolean;
    types?: {
      adaptive?: { supported: boolean };
      enabled?: { supported: boolean };
    };
  };
  effort?: {
    supported: boolean;
    low?: { supported: boolean };
    medium?: { supported: boolean };
    high?: { supported: boolean };
    max?: { supported: boolean };
  };
  batch?: { supported: boolean };
  citations?: { supported: boolean };
  structured_outputs?: { supported: boolean };
  code_execution?: { supported: boolean };
}

/** SSE events from streaming messages */
export interface AnthropicStreamMessageStart {
  type: 'message_start';
  message: {
    id: string;
    model: string;
    usage: { input_tokens: number; output_tokens: number };
  };
}

export interface AnthropicStreamContentDelta {
  type: 'content_block_delta';
  delta: { type: 'text_delta'; text: string };
}

export interface AnthropicStreamMessageDelta {
  type: 'message_delta';
  usage: { output_tokens: number };
}

export interface AnthropicStreamMessageStop {
  type: 'message_stop';
}

export type AnthropicStreamEvent =
  | AnthropicStreamMessageStart
  | AnthropicStreamContentDelta
  | AnthropicStreamMessageDelta
  | AnthropicStreamMessageStop
  | { type: string }; // other events we skip

export interface AnthropicUsage {
  input_tokens: number;
  output_tokens: number;
}
