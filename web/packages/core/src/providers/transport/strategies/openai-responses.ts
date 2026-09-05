/**
 * OpenAI Responses API Strategy
 *
 * Covers openAI (gpt-4o / 4.1 / 5 / 5.5) and grok (4.1+, through the Agent Tools API).
 *
 * Endpoint: POST /v1/responses
 * Request: { model, input: [{role, content: [{type, text}]}], tools: [{type:"web_search"}], ... }
 * Response SSE:
 *   - `event: response.output_text.delta` data: { delta: "..." }
 *   - `event: response.output_item.added` data: { item: { type, ... } }
 *   - `event: response.output_text.annotations.added` data: { annotation: { type: "url_citation", url, title, start_index, end_index } }
 *   - `event: response.completed` data: { response: { usage } }
 *
 * Citations come from the fields nested in an annotation with type=="url_citation".
 */

import type { ContentPart, StreamEvent } from '../../types';
import type {
  BuildRequestInput,
  StreamContext,
  TransportStrategy,
} from '../transport-strategy';
import { citationFromRaw, mergeCitation, readPath } from '../citation-utils';
import { deepMerge } from '../merge-utils';
import { normalizeResponsesUsage, parseUsageGrok, parseUsageOpenAI } from '../usage-parsers';
import { nativeToolCallEvents } from '../../tool-call-protocol';

function buildResponsesContent(
  role: 'user' | 'assistant' | 'system',
  content: string | ContentPart[],
): Array<Record<string, unknown>> {
  const inputTextType = role === 'assistant' ? 'output_text' : 'input_text';
  if (typeof content === 'string') {
    return [{ type: inputTextType, text: content }];
  }
  return content.map((p) => {
    if (p.type === 'text') return { type: inputTextType, text: p.text };
    if (p.type === 'image_url') {
      // Explicit detail field, defaulting to 'auto'
      const block: Record<string, unknown> = {
        type: 'input_image',
        image_url: p.image_url.url,
      };
      if (p.image_url.detail) block.detail = p.image_url.detail;
      return block;
    }
    if (p.type === 'file') {
      // Any file part routed as native goes through input_file, which covers PDF plus the 8 Office
      // mime types. AttachmentRouter already made that decision upstream in chat-stream-utils, so
      // reaching here means the native path.
      if (p.file.file_data) {
        return {
          type: 'input_file',
          filename: p.file.filename,
          file_data: p.file.file_data,
        };
      }
      // Fall back to text when file_data is missing
      return { type: inputTextType, text: `[File: ${p.file.filename}]` };
    }
    // video_url and other fallbacks: describe it in text
    if (p.type === 'video_url') {
      return { type: inputTextType, text: `[video: ${p.video_url.url}]` };
    }
    return { type: inputTextType, text: '[unsupported]' };
  });
}

// Relay exception / heuristic allow: a user-defined OpenAI Responses endpoint has no official profile to rely on.
function relayOpenAIResponsesEffort(mode: string): 'low' | 'medium' | 'high' {
  switch (mode) {
    case 'fast':
      return 'low';
    case 'balanced':
      return 'medium';
    case 'deep':
    case 'max':
      return 'high';
    default:
      return 'medium';
  }
}

export const openAIResponsesStrategy: TransportStrategy = {
  kind: 'openai_responses',
  buildRequestBody(input: BuildRequestInput): Record<string, unknown> {
    const body: Record<string, unknown> = {
      model: input.modelID,
      stream: true,
      input: input.messages.map((m) => ({
        role: m.role,
        content: buildResponsesContent(m.role, m.content),
      })),
    };
    // summary is mandatory: without it OpenAI Responses does not emit
    // `response.reasoning_summary_text.delta`, so the reasoning never reaches the UI. In automatic
    // mode effort is left out so the model decides, but reasoning={summary:'auto'} is still sent;
    // OpenAI accepts summary without effort and still streams reasoning summary deltas.
    if (input.options?.reasoning && input.options.reasoning !== 'automatic') {
      body.reasoning = { effort: relayOpenAIResponsesEffort(input.options.reasoning), summary: 'auto' };
    } else {
      body.reasoning = { summary: 'auto' };
    }
    if (input.mergeParams) deepMerge(body, input.mergeParams);
    return body;
  },
  parseStreamChunk(eventType, data, ctx, shape) {
    let payload: Record<string, unknown>;
    try {
      payload = JSON.parse(data);
    } catch {
      return null;
    }
    const events: StreamEvent[] = [];
    const type = eventType ?? (typeof payload.type === 'string' ? payload.type : '');
    events.push(...nativeToolCallEvents('openai_responses', eventType, payload));
    let citationChanged = false;

    if (type === 'response.output_text.delta') {
      const delta = typeof payload.delta === 'string' ? payload.delta : '';
      if (delta) events.push({ type: 'delta', content: delta });
    } else if (
      // gpt-5 and the o-series actually emit `response.reasoning_summary_text.delta`, while older
      // documentation and some variants send `response.reasoning.delta` or
      // `response.reasoning_summary.delta`, so all three are covered.
      type === 'response.reasoning.delta' ||
      type === 'response.reasoning_summary.delta' ||
      type === 'response.reasoning_summary_text.delta'
    ) {
      const delta = typeof payload.delta === 'string' ? payload.delta : '';
      if (delta) events.push({ type: 'reasoning', content: delta });
    } else if (
      type === 'response.output_text.annotations.added' ||
      type === 'response.output_text.annotation.added'
    ) {
      const ann = payload.annotation as Record<string, unknown> | undefined;
      if (ann && ann.type === 'url_citation') {
        const changed = mergeCitation(ctx.citations, {
          url: typeof ann.url === 'string' ? ann.url : '',
          title: typeof ann.title === 'string' ? ann.title : undefined,
          startIndex: typeof ann.start_index === 'number' ? ann.start_index : undefined,
          endIndex: typeof ann.end_index === 'number' ? ann.end_index : undefined,
        });
        if (changed) citationChanged = true;
      }
    } else if (type === 'response.completed' || type === 'response.done') {
      const resp = payload.response as Record<string, unknown> | undefined;
      const usage = resp?.usage as Record<string, unknown> | undefined;
      if (usage) {
        // Responses usage has the same semantics as chat but a different detail path
        // (input_tokens_details / output_tokens_details). Normalizing the top-level names together
        // with the detail paths lets the same parser be reused; Grok's own cost_in_usd_ticks needs a
        // dedicated parser.
        const adapted = normalizeResponsesUsage(usage);
        const breakdown =
          ctx.providerKind === 'grok' ? parseUsageGrok(adapted) : parseUsageOpenAI(adapted);
        events.push({
          type: 'usage',
          usage: {
            prompt_tokens: typeof usage.input_tokens === 'number' ? usage.input_tokens : undefined,
            completion_tokens:
              typeof usage.output_tokens === 'number' ? usage.output_tokens : undefined,
            total_tokens: typeof usage.total_tokens === 'number' ? usage.total_tokens : undefined,
            breakdown,
          },
        });
      }
      // The output may carry web_search_call or message items; annotations were already handled on the added event
    }
    // Custom citation path from streamShape: readPath resolves the dot notation, as in the other strategies
    if (shape?.citationsArrayPath) {
      const arr = readPath(payload, shape.citationsArrayPath);
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
