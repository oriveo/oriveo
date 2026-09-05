/**
 * Closed enumeration of transport kinds.
 *
 * The client picks its protocol strategy class from this value.
 * An unknown kind makes the registry report telemetry and throw UnsupportedTransportError,
 * on which the layer above should hide the model from the picker.
 */

export const TRANSPORT_KINDS = [
  'openai_chat',
  'openai_responses',
  'anthropic_messages',
  'gemini_generate',
  'dashscope_native',
  'openai_images',
  'gemini_image',
  'qwen_image',
  'grok_image',
  'zhipu_image',
  'anthropic_files',
  'openai_files',
] as const;

export type TransportKind = (typeof TRANSPORT_KINDS)[number];

export const TRANSPORT_KIND_SET: ReadonlySet<string> = new Set(TRANSPORT_KINDS);

/** Endpoint kind used by EndpointResolver. */
export type EndpointKind = 'chat' | 'responses' | 'images' | 'embeddings' | 'files';

export function isKnownTransportKind(kind: string | undefined | null): kind is TransportKind {
  return typeof kind === 'string' && TRANSPORT_KIND_SET.has(kind);
}

/**
 * Default endpoint kind for each transport kind.
 *
 * Different transports within one provider use different endpoints (OpenAI's `gpt-4o` goes
 * to `/v1/responses` while `gpt-3.5-turbo` goes to `/v1/chat/completions`), and this mapping
 * lets adapter-helpers pick the right endpoint path when dispatching by strategy, so a
 * Responses request never reaches the chat endpoint.
 *
 * Non-streaming kinds such as files and embeddings keep the 'chat' fallback; extend this
 * when one of them is actually needed.
 */
export function endpointKindForTransport(kind: string): EndpointKind {
  switch (kind) {
    case 'openai_responses':
      return 'responses';
    case 'openai_images':
    case 'gemini_image':
    case 'qwen_image':
    case 'grok_image':
    case 'zhipu_image':
      return 'images';
    case 'openai_files':
    case 'anthropic_files':
      return 'files';
    default:
      // openai_chat / anthropic_messages / gemini_generate / dashscope_native
      return 'chat';
  }
}

export class UnsupportedTransportError extends Error {
  readonly kind: string;
  constructor(kind: string) {
    super(`Unsupported transport kind: ${kind}`);
    this.name = 'UnsupportedTransportError';
    this.kind = kind;
  }
}
