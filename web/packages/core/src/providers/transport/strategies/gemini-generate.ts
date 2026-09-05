/**
 * Gemini generateContent Strategy
 *
 * Endpoint: POST /v1beta/models/{model}:streamGenerateContent?alt=sse
 * Request shape: { contents: [...], systemInstruction?, generationConfig?, tools? }
 *
 * Citation parsing (the REST API uses camelCase, not snake_case):
 *   - default path: candidates.0.groundingMetadata.groundingChunks[]
 *   - each chunk carries web.uri + web.title
 *   - streamShape.citationsArrayPath overrides the path
 *   - streamShape.citationUrlField overrides the URL field (default "web.uri")
 *   - streamShape.citationTitleField overrides the title field (default "web.title")
 */

import type { ContentPart, StreamEvent } from '../../types';
import type {
  BuildRequestInput,
  StreamContext,
  TransportStrategy,
} from '../transport-strategy';
import { citationFromRaw, mergeCitation, readPath } from '../citation-utils';
import { deepMerge } from '../merge-utils';
import { parseUsageGemini } from '../usage-parsers';
import { nativeToolCallEvents } from '../../tool-call-protocol';

function convertToGeminiParts(parts: ContentPart[]): Array<Record<string, unknown>> {
  return parts.map((p) => {
    if (p.type === 'text') {
      return { text: p.text };
    }
    if (p.type === 'image_url') {
      const url = p.image_url.url;
      const match = url.match(/^data:([^;]+);base64,(.+)$/);
      if (match) return { inlineData: { mimeType: match[1], data: match[2] } };
      return { text: `[image: ${url}]` };
    }
    if (p.type === 'video_url') {
      const match = p.video_url.url.match(/^data:([^;]+);base64,(.+)$/);
      if (match) return { inlineData: { mimeType: match[1], data: match[2] } };
      return { text: `[video: ${p.video_url.url}]` };
    }
    if (p.type === 'file') {
      // Any file part with route=native goes through inlineData, which covers both the
      // native PDF default (pdfNativeDefault=true) and the scanned_pdf fallback.
      if (p.file.file_data) {
        const match = p.file.file_data.match(/^data:([^;]+);base64,(.+)$/);
        if (match) return { inlineData: { mimeType: match[1], data: match[2] } };
      }
      return { text: `[File: ${p.file.filename}]` };
    }
    return { text: '[unsupported]' };
  });
}

// Relay and heuristic-allow exception: a user-defined Gemini-compatible endpoint has no official profile to rely on.
function relayGeminiThinkingBudget(mode: string): number {
  // gemini-2.5-pro caps thinkingBudget at 24576, and a higher value such as 32768 is
  // rejected by the Gemini API, so every client uses the same numbers.
  switch (mode) {
    case 'fast':
      return 1024;
    case 'balanced':
      return 4096;
    case 'deep':
      return 16384;
    case 'max':
      return 24576;
    default:
      return 4096;
  }
}

/** Relay exception: a Gemini-compatible custom endpoint has no official profile to rely on. */
function relayUsesGeminiThinkingLevel(modelID: string): boolean {
  const lowered = modelID.toLowerCase();
  // heuristic-allow: Relay Gemini-compatible fallback only; official Gemini passes providerKind !== "relay".
  return lowered.includes('3.1') || lowered.includes('gemini-3');
}

function relayGeminiThinkingLevel(mode: string): 'LOW' | 'MEDIUM' | 'HIGH' {
  switch (mode) {
    case 'fast':
      return 'LOW';
    case 'balanced':
      return 'MEDIUM';
    case 'deep':
    case 'max':
      return 'HIGH';
    default:
      return 'MEDIUM';
  }
}

const DEFAULT_CITATIONS_PATH = 'candidates.0.groundingMetadata.groundingChunks';
const DEFAULT_URL_FIELD = 'web.uri';
const DEFAULT_TITLE_FIELD = 'web.title';

/**
 * Gemini finishReason values that mean the content policy stopped generation. Letting one
 * pass silently makes a truncated or empty reply look like a normal completion.
 * STOP / MAX_TOKENS / null / undefined are normal completions and are not listed here.
 */
export const GEMINI_BLOCKED_FINISH_REASONS = new Set([
  'SAFETY',
  'RECITATION',
  'PROHIBITED_CONTENT',
  'BLOCKLIST',
  'SPII',
]);

/**
 * Gemini signals interception through fields inside an HTTP 200 stream rather than an HTTP error:
 *   - promptFeedback.blockReason: the prompt was rejected outright, usually with no candidates and no output at all;
 *   - candidates[].finishReason hitting a content policy: generation was cut off mid-way.
 * Returns an error event on a hit (readStream turns it into a thrown ProviderError), null otherwise.
 * Shared by the direct strategy and the proxy parseProxyChunk so both paths mean the same thing.
 */
export function detectGeminiBlockEvent(
  chunk: Record<string, unknown>,
): Extract<StreamEvent, { type: 'error' }> | null {
  const promptFeedback = chunk.promptFeedback as Record<string, unknown> | undefined;
  const blockReason = promptFeedback?.blockReason;
  if (typeof blockReason === 'string' && blockReason) {
    return {
      type: 'error',
      error: `Gemini blocked the prompt (blockReason=${blockReason}).`,
      errorKind: 'upstream',
      source: 'provider',
    };
  }
  const candidates = chunk.candidates as Array<Record<string, unknown>> | undefined;
  const finishReason = candidates?.[0]?.finishReason;
  if (typeof finishReason === 'string' && GEMINI_BLOCKED_FINISH_REASONS.has(finishReason)) {
    return {
      type: 'error',
      error: `Gemini stopped the response (finishReason=${finishReason}).`,
      errorKind: 'upstream',
      source: 'provider',
    };
  }
  return null;
}

export const geminiGenerateStrategy: TransportStrategy = {
  kind: 'gemini_generate',
  buildRequestBody(input: BuildRequestInput): Record<string, unknown> {
    const useRelayFallbacks = input.providerKind === 'relay';
    const systemTexts = input.messages
      .filter((m) => m.role === 'system')
      .map((m) =>
        typeof m.content === 'string'
          ? m.content
          : m.content
              .map((p) => (p.type === 'text' ? p.text : ''))
              .join(''),
      )
      .filter(Boolean);

    const contents = input.messages
      .filter((m) => m.role !== 'system')
      .map((m) => ({
        role: m.role === 'assistant' ? 'model' : 'user',
        parts:
          typeof m.content === 'string' ? [{ text: m.content }] : convertToGeminiParts(m.content),
      }));

    const body: Record<string, unknown> = { contents };
    if (systemTexts.length > 0) {
      body.systemInstruction = { parts: [{ text: systemTexts.join('\n\n') }] };
    }
    const genConfig: Record<string, unknown> = {};
    // Official Gemini only accepts injection through metadata profile.mergeParams; the local fallback is Relay-only.
    if (useRelayFallbacks && input.options?.reasoning && input.options.reasoning !== 'automatic') {
      if (relayUsesGeminiThinkingLevel(input.modelID)) {
        // Gemini 3.x takes a thinkingLevel string rather than a thinkingBudget number, as the API requires.
        genConfig.thinkingConfig = {
          thinkingLevel: relayGeminiThinkingLevel(input.options.reasoning),
          includeThoughts: true,
        };
      } else {
        genConfig.thinkingConfig = {
          thinkingBudget: relayGeminiThinkingBudget(input.options.reasoning),
          includeThoughts: true,
        };
      }
    } else if (useRelayFallbacks) {
      genConfig.thinkingConfig = { includeThoughts: true };
    }
    if (useRelayFallbacks && input.options?.supportsImageGen) {
      // Relay and heuristic-allow exception: official Gemini image generation is injected through imageGen profile mergeParams.
      genConfig.responseModalities = ['TEXT', 'IMAGE'];
    }
    if (Object.keys(genConfig).length > 0) body.generationConfig = genConfig;

    if (input.mergeParams) deepMerge(body, input.mergeParams);
    return body;
  },
  parseStreamChunk(_eventType, data, ctx, shape) {
    let chunk: Record<string, unknown>;
    try {
      chunk = JSON.parse(data);
    } catch {
      return null;
    }

    // A top-level {"error":{...}} chunk mid-stream: upstream can still fail inside the
    // stream after an HTTP 200, and swallowing it silently turns into an empty response.
    if (chunk.error) {
      const errObj = chunk.error as Record<string, unknown> | string;
      const message =
        typeof errObj === 'string'
          ? errObj
          : typeof errObj.message === 'string' && errObj.message
            ? errObj.message
            : 'Gemini stream error';
      return [{ type: 'error', error: message, errorKind: 'upstream', source: 'provider' }];
    }

    // Content interception (blockReason or a content-policy finishReason): on a hit, drop
    // the rest of the chunk (parts/usage) rather than parsing it.
    const blocked = detectGeminiBlockEvent(chunk);
    if (blocked) return [blocked];

    const events: StreamEvent[] = [];
    events.push(...nativeToolCallEvents('gemini_generate_content', _eventType, chunk));

    const candidates = chunk.candidates as Array<Record<string, unknown>> | undefined;
    const parts = (candidates?.[0]?.content as Record<string, unknown> | undefined)?.parts as
      | Array<Record<string, unknown>>
      | undefined;
    if (parts) {
      for (const part of parts) {
        if (typeof part.text === 'string' && part.text) {
          // A thinking-capable Gemini model asked for includeThoughts:true returns parts
          // marked `thought: true` for its reasoning; route those to reasoning and the rest to the body delta.
          if (part.thought === true) {
            events.push({ type: 'reasoning', content: part.text });
          } else {
            events.push({ type: 'delta', content: part.text });
          }
        }
        const inlineData = part.inlineData as Record<string, unknown> | undefined;
        if (inlineData?.mimeType && inlineData?.data) {
          events.push({
            type: 'image',
            url: `data:${inlineData.mimeType};base64,${inlineData.data}`,
          });
        }
      }
    }

    const usage = chunk.usageMetadata as Record<string, unknown> | undefined;
    if (usage) {
      const breakdown = parseUsageGemini(usage);
      // The older prompt_tokens / completion_tokens fields stay for telemetry compatibility:
      // breakdown.completionTokens already includes thoughts, but the legacy telemetry
      // fields keep reading candidatesTokenCount directly so historical numbers stay comparable.
      events.push({
        type: 'usage',
        usage: {
          prompt_tokens:
            typeof usage.promptTokenCount === 'number' ? usage.promptTokenCount : undefined,
          completion_tokens:
            typeof usage.candidatesTokenCount === 'number' ? usage.candidatesTokenCount : undefined,
          total_tokens:
            typeof usage.totalTokenCount === 'number' ? usage.totalTokenCount : undefined,
          breakdown,
        },
      });
    }

    // Citations (groundingMetadata.groundingChunks)
    const path = shape?.citationsArrayPath ?? DEFAULT_CITATIONS_PATH;
    const arr = readPath(chunk, path);
    let citationChanged = false;
    if (Array.isArray(arr)) {
      for (const raw of arr) {
        const c = citationFromRaw(raw, shape, {
          urlField: shape?.citationUrlField ?? DEFAULT_URL_FIELD,
          titleField: shape?.citationTitleField ?? DEFAULT_TITLE_FIELD,
          snippetField: shape?.citationSnippetField ?? 'snippet',
        });
        if (mergeCitation(ctx.citations, c)) citationChanged = true;
      }
    }
    if (citationChanged) {
      events.push({ type: 'citations', citations: ctx.citations.slice() });
    }

    return events.length > 0 ? events : null;
  },
  parseError(status, body) {
    return { message: typeof body === 'string' ? body : `HTTP ${status}` };
  },
};
