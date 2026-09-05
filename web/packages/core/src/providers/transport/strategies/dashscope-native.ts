/**
 * DashScope native mode strategy (Qwen)
 *
 * Endpoint: POST /api/v1/services/aigc/text-generation/generation
 * Request shape:
 *   {
 *     model,
 *     input: { messages: [{role, content}] },
 *     parameters: {
 *       result_format: "message",
 *       incremental_output: true,
 *       enable_search?: true,
 *       search_options?: {...},
 *       enable_thinking?: true,
 *       thinking_budget?: number
 *     }
 *   }
 *
 * Streaming SSE: DashScope pushes each chunk as
 *   data: { "output": { "choices": [{"message": {"content": "..."}}] },
 *           "usage": { "input_tokens": ..., "output_tokens": ... } }
 *
 * Citation parsing:
 *   - Default path: output.search_info.search_results[]
 *   - Each entry has site_name / icon / index / title / url
 *   - streamShape override supported (forward compatibility)
 */

import type { ContentPart, StreamEvent } from '../../types';
import type {
  BuildRequestInput,
  StreamContext,
  TransportStrategy,
} from '../transport-strategy';
import { citationFromRaw, mergeCitation, readPath } from '../citation-utils';
import { deepMerge } from '../merge-utils';
import { parseUsageQwen } from '../usage-parsers';

function partsToString(parts: ContentPart[]): string {
  // DashScope documents multimodal messages separately; text is the default aggregation here
  // (Qwen-Plus / Max / Turbo all take text on the main path). Qwen is not on the native_pdf list,
  // so a file part should never arrive; if one does, turn it into a text note as a safety net.
  return parts
    .map((p) => {
      if (p.type === 'text') return p.text;
      if (p.type === 'image_url') return `[image: ${p.image_url.url}]`;
      if (p.type === 'video_url') return `[video: ${p.video_url.url}]`;
      if (p.type === 'file') {
        // Safety net: Qwen does not support native PDF, so emit an explanatory error
        if (p.file.extractionErrorCode) {
          return `[File: ${p.file.filename}]\n[ERROR: extraction failed - ${p.file.extractionErrorCode}]`;
        }
        return `[File: ${p.file.filename}]`;
      }
      return '';
    })
    .join('\n');
}

// Relay exception / heuristic-allow: a user-defined DashScope-compatible endpoint has no official profile to rely on.
function relayDashScopeThinkingBudget(mode: string): number {
  // Max=38000 (the Qwen3 thinking_budget cap is 38912, leaving a 912 buffer).
  switch (mode) {
    case 'fast':
      return 2048;
    case 'balanced':
      return 8192;
    case 'deep':
      return 16384;
    case 'max':
      return 38000;
    default:
      return 8192;
  }
}

const DEFAULT_CITATIONS_PATH = 'output.search_info.search_results';

export const dashscopeNativeStrategy: TransportStrategy = {
  kind: 'dashscope_native',
  buildRequestBody(input: BuildRequestInput): Record<string, unknown> {
    const apiMessages = input.messages.map((m) => ({
      role: m.role,
      content: typeof m.content === 'string' ? m.content : partsToString(m.content),
    }));

    const parameters: Record<string, unknown> = {
      result_format: 'message',
      incremental_output: true,
    };
    // Same as openai-chat / anthropic-messages / gemini-generate: the local thinking_budget
    // mapping is a relay exception, while official DashScope goes through params[level] in the
    // metadata profile. Without the gate an official model would get the locally hardcoded budget.
    if (
      input.providerKind === 'relay' &&
      input.options?.reasoning &&
      input.options.reasoning !== 'automatic'
    ) {
      parameters.enable_thinking = true;
      parameters.thinking_budget = relayDashScopeThinkingBudget(input.options.reasoning);
    }

    const body: Record<string, unknown> = {
      model: input.modelID,
      input: { messages: apiMessages },
      parameters,
    };

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
    const events: StreamEvent[] = [];

    const output = chunk.output as Record<string, unknown> | undefined;
    if (output) {
      // message format: output.choices[0].message.content
      const choices = output.choices as Array<Record<string, unknown>> | undefined;
      const msg = choices?.[0]?.message as Record<string, unknown> | undefined;
      const content = msg?.content;
      if (typeof content === 'string' && content) {
        events.push({ type: 'delta', content });
      }
      // text format fallback: output.text
      if (!content && typeof output.text === 'string' && output.text) {
        events.push({ type: 'delta', content: output.text });
      }
      // reasoning: output.choices[0].message.reasoning_content
      const reasoning = msg?.reasoning_content;
      if (typeof reasoning === 'string' && reasoning) {
        events.push({ type: 'reasoning', content: reasoning });
      }
    }

    const usage = chunk.usage as Record<string, unknown> | undefined;
    if (usage) {
      const breakdown = parseUsageQwen(usage);
      events.push({
        type: 'usage',
        usage: {
          prompt_tokens:
            typeof usage.input_tokens === 'number' ? usage.input_tokens : undefined,
          completion_tokens:
            typeof usage.output_tokens === 'number' ? usage.output_tokens : undefined,
          total_tokens:
            typeof usage.total_tokens === 'number' ? usage.total_tokens : undefined,
          breakdown,
        },
      });
    }

    // Citations: output.search_info.search_results[]
    const path = shape?.citationsArrayPath ?? DEFAULT_CITATIONS_PATH;
    const arr = readPath(chunk, path);
    let citationChanged = false;
    if (Array.isArray(arr)) {
      for (const raw of arr) {
        const c = citationFromRaw(raw, shape, {
          urlField: 'url',
          titleField: 'title',
          snippetField: 'snippet',
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
