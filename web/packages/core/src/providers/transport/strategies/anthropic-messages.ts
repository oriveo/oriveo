/**
 * Anthropic Messages Strategy
 *
 * Endpoint: POST /v1/messages
 * Request shape:
 *   { model, max_tokens, stream, messages: [{role, content: [{type, text}]}],
 *     system?, thinking?, tools? }
 *
 * Citation parsing:
 *   - a content_block_start whose block has `type=="web_search_tool_result"`
 *   - block.content[].url + content[].title + content[].cited_text
 *   - streamShape.citationsBlockType can override the block type
 *   - streamShape.citationSnippetField defaults to "cited_text"
 */

import type { ContentPart, StreamEvent } from '../../types';
import type {
  BuildRequestInput,
  StreamContext,
  TransportStrategy,
} from '../transport-strategy';
import { citationFromRaw, mergeCitation } from '../citation-utils';
import { deepMerge } from '../merge-utils';
import { parseUsageAnthropic } from '../usage-parsers';
import { nativeToolCallEvents } from '../../tool-call-protocol';

/**
 * Anthropic prompt caching is enabled automatically.
 * Native PDF and image content blocks carry cache_control: ephemeral (5 min TTL).
 * Asking 5 questions about a 100-page PDF costs $7 instead of $25, a 72% saving.
 * The dedupe key is derived server-side from a content hash, so the client does not manage it.
 */
const ANTHROPIC_CACHE_CONTROL = { type: 'ephemeral' } as const;

function convertToAnthropicParts(parts: ContentPart[]): Array<Record<string, unknown>> {
  return parts.map((p) => {
    if (p.type === 'text') {
      return { type: 'text', text: p.text };
    }
    if (p.type === 'image_url') {
      const url = p.image_url.url;
      const match = url.match(/^data:([^;]+);base64,(.+)$/);
      if (match) {
        return {
          type: 'image',
          source: { type: 'base64', media_type: match[1], data: match[2] },
          cache_control: ANTHROPIC_CACHE_CONTROL,
        };
      }
      return { type: 'text', text: `[image: ${url}]` };
    }
    if (p.type === 'video_url') {
      return { type: 'text', text: `[video: ${p.video_url.url}]` };
    }
    if (p.type === 'file') {
      // A file part only appears when route=native; that decision is made upstream in chat-stream-utils.
      if (p.file.file_data) {
        const match = p.file.file_data.match(/^data:([^;]+);base64,(.+)$/);
        if (match) {
          return {
            type: 'document',
            source: { type: 'base64', media_type: match[1], data: match[2] },
            cache_control: ANTHROPIC_CACHE_CONTROL,
          };
        }
      }
      // Fall back to text when file_data is missing.
      return { type: 'text', text: `[File: ${p.file.filename}]` };
    }
    return { type: 'text', text: '[unsupported]' };
  });
}

function extractText(parts: ContentPart[]): string {
  return parts
    .filter((p) => p.type === 'text')
    .map((p) => (p as { type: 'text'; text: string }).text)
    .join('\n');
}

// Relay-only heuristic fallback: a user-defined Anthropic-compatible endpoint has no official profile to follow.
function relayAnthropicBudgetTokens(mode: string): number {
  switch (mode) {
    case 'fast':
      return 2048;
    case 'balanced':
      return 8192;
    case 'deep':
      return 16384;
    case 'max':
      // Matches the shared formula 24576 + max_tokens = max(8192, budget+4096) = 28672, which stays
      // under claude-opus-4-1's 32000 max_output limit (32768 makes opus return 400).
      return 24576;
    default:
      return 8192;
  }
}

const DEFAULT_BLOCK_TYPE = 'web_search_tool_result';
const DEFAULT_SNIPPET_FIELD = 'cited_text';

export const anthropicMessagesStrategy: TransportStrategy = {
  kind: 'anthropic_messages',
  buildRequestBody(input: BuildRequestInput): Record<string, unknown> {
    let systemText: string | undefined;
    const apiMessages: Array<Record<string, unknown>> = [];
    for (const m of input.messages) {
      if (m.role === 'system') {
        systemText = typeof m.content === 'string' ? m.content : extractText(m.content);
        continue;
      }
      apiMessages.push({
        role: m.role,
        content: typeof m.content === 'string' ? m.content : convertToAnthropicParts(m.content),
      });
    }

    const body: Record<string, unknown> = {
      model: input.modelID,
      // Relay-only heuristic fallback; official Anthropic goes through request-builders plus provider metadata.
      max_tokens: 8192,
      stream: true,
      messages: apiMessages,
    };
    if (systemText) body.system = systemText;

    // As in openai-chat, the local budget mapping is a Relay-only exception: official Anthropic uses the
    // metadata profile's params[level] (ant_budget / ant_adaptive*). Without that gate an official model
    // would pick up the hardcoded local budget.
    if (
      input.providerKind === 'relay' &&
      input.options?.reasoning &&
      input.options.reasoning !== 'automatic'
    ) {
      const budgetTokens = relayAnthropicBudgetTokens(input.options.reasoning);
      body.thinking = { type: 'enabled', budget_tokens: budgetTokens };
      body.max_tokens = Math.max(8192, budgetTokens + 4096);
    }

    if (input.mergeParams) deepMerge(body, input.mergeParams);
    return body;
  },
  parseStreamChunk(eventType, data, ctx, shape) {
    let event: Record<string, unknown>;
    try {
      event = JSON.parse(data);
    } catch {
      return null;
    }
    const type = eventType ?? (typeof event.type === 'string' ? event.type : '');
    const events: StreamEvent[] = [];
    events.push(...nativeToolCallEvents('anthropic_messages', eventType, event));

    switch (type) {
      case 'message_start': {
        const usage = ((event.message as Record<string, unknown> | undefined)?.usage ?? {}) as Record<
          string,
          unknown
        >;
        const inputTokens = typeof usage.input_tokens === 'number' ? usage.input_tokens : 0;
        ctx.inputTokens = inputTokens;
        // Keep the full message_start usage, including the nested cache_read / cache_creation counts, and
        // merge output_tokens at message_delta time to compute the breakdown.
        ctx.state.anthropicUsage = usage;
        return events.length > 0 ? events : null;
      }
      case 'content_block_start': {
        // Handle a web_search_tool_result block.
        const block = event.content_block as Record<string, unknown> | undefined;
        if (block) {
          const changed = handleContentBlock(block, ctx, shape);
          if (changed) {
            events.push({ type: 'citations', citations: ctx.citations.slice() });
          }
        }
        break;
      }
      case 'content_block_delta': {
        const delta = event.delta as Record<string, unknown> | undefined;
        if (delta?.type === 'text_delta' && typeof delta.text === 'string' && delta.text) {
          events.push({ type: 'delta', content: delta.text });
        } else if (
          delta?.type === 'thinking_delta' &&
          typeof delta.thinking === 'string' &&
          delta.thinking
        ) {
          events.push({ type: 'reasoning', content: delta.thinking });
        }
        break;
      }
      case 'message_delta': {
        const usage = event.usage as Record<string, unknown> | undefined;
        const outputTokens = typeof usage?.output_tokens === 'number' ? usage.output_tokens : 0;
        // Merge the usage saved at message_start (with cache_read / cache_creation) with the current output_tokens.
        const startUsage =
          (ctx.state.anthropicUsage as Record<string, unknown> | undefined) ?? {};
        const merged: Record<string, unknown> = {
          ...startUsage,
          output_tokens: outputTokens,
        };
        const breakdown = parseUsageAnthropic(merged);
        events.push({
          type: 'usage',
          usage: {
            prompt_tokens: ctx.inputTokens,
            completion_tokens: outputTokens,
            total_tokens: ctx.inputTokens + outputTokens,
            breakdown,
          },
        });
        break;
      }
      default:
        return events.length > 0 ? events : null;
    }
    return events.length > 0 ? events : null;
  },
  parseError(status, body) {
    return { message: typeof body === 'string' ? body : `HTTP ${status}` };
  },
};

function handleContentBlock(
  block: Record<string, unknown>,
  ctx: StreamContext,
  shape: import('@oriveo/core/metadata/types').StreamShape | null,
): boolean {
  const blockType = shape?.citationsBlockType ?? DEFAULT_BLOCK_TYPE;
  if (block.type !== blockType) return false;
  const content = block.content;
  if (!Array.isArray(content)) return false;
  let changed = false;
  for (const raw of content) {
    const c = citationFromRaw(raw, shape, {
      urlField: 'url',
      titleField: 'title',
      snippetField: DEFAULT_SNIPPET_FIELD,
    });
    if (mergeCitation(ctx.citations, c)) changed = true;
  }
  return changed;
}
