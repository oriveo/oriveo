/**
 * Skeletons for the Image and Files strategies.
 *
 * These strategies are metadata-only placeholders for now: image generation on the web
 * goes through the `/api/images/generate` server proxy rather than speaking the upstream
 * protocol directly.
 *
 * When the client does connect directly, fill in buildRequestBody and parseStreamChunk on
 * each strategy and drop the placeholders.
 */

import type { StreamEvent } from '../../types';
import type {
  BuildRequestInput,
  StreamContext,
  TransportStrategy,
} from '../transport-strategy';
import type { TransportKind } from '../transport-kind';

function emptyParse(): StreamEvent[] | null {
  return null;
}

function emptyBody(input: BuildRequestInput): Record<string, unknown> {
  return {
    model: input.modelID,
    prompt:
      typeof input.messages[0]?.content === 'string' ? input.messages[0].content : '',
  };
}

function emptyError(status: number, body: unknown): { message: string } {
  return { message: typeof body === 'string' ? body : `HTTP ${status}` };
}

function createImageStrategy(kind: TransportKind): TransportStrategy {
  return {
    kind,
    buildRequestBody: (input: BuildRequestInput) => emptyBody(input),
    parseStreamChunk: (
      _eventType: string | null,
      _data: string,
      _ctx: StreamContext,
      // streamShape reserves imageDataPath for tuning the image protocols.
    ): StreamEvent[] | null => emptyParse(),
    parseError: (status, body) => emptyError(status, body),
  };
}

export const openAIImagesStrategy = createImageStrategy('openai_images');
export const geminiImageStrategy = createImageStrategy('gemini_image');
export const qwenImageStrategy = createImageStrategy('qwen_image');
export const grokImageStrategy = createImageStrategy('grok_image');
export const zhipuImageStrategy = createImageStrategy('zhipu_image');
export const anthropicFilesStrategy = createImageStrategy('anthropic_files');
export const openAIFilesStrategy = createImageStrategy('openai_files');
