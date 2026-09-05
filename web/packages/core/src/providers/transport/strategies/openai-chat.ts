/**
 * OpenAI Chat Completions strategy, including every OpenAI-compatible aggregator.
 *
 * Covers: openAI (chat route) / groq / together / fireworks / siliconFlow /
 * deepseek / minimax / moonshot / zhipu / openRouter / relay.
 *
 * Citation parsing:
 *   - by default, `type=="url_citation"` entries are looked up in
 *     `choices.0.delta.annotations[]` / `choices.0.message.annotations[]` and normalised.
 *   - streamShape.citationsArrayPath overrides the path (Zhipu uses
 *     `choices.0.delta.tool_calls.0.web_search.search_result`).
 *   - streamShape.citationUrlField overrides the field name (Zhipu uses `link`).
 */

import type { ContentPart, StreamEvent } from '../../types';
import type { StreamShape } from '@oriveo/core/metadata/types';
import type {
  BuildRequestInput,
  StreamContext,
  TransportStrategy,
} from '../transport-strategy';
import { citationFromRaw, mergeCitation, readPath } from '../citation-utils';
import { parseContentBlockArray } from '../content-block-parser';
import { nativeToolCallEvents } from '../../tool-call-protocol';
import { deepMerge } from '../merge-utils';
import {
  parseUsageMoonshot,
  parseUsageOpenAI,
  parseUsageOpenAICompatible,
  parseUsageOpenRouter,
  parseUsageGrok,
  parseUsageDeepSeek,
} from '../usage-parsers';
import type { UsageBreakdown } from '../../../chat/usage-breakdown';
import {
  createThinkingTagParserState,
  parseThinkingTaggedDelta,
  type ThinkingTagParserState,
} from '../thinking-tag-parser';

/**
 * Pick a UsageBreakdown parser by providerKind.
 *
 * The openai_chat strategy covers a dozen providers whose usage fields differ widely:
 *   - Moonshot reports cached_tokens at the top level (OpenAI nests it under prompt_tokens_details)
 *   - Grok adds cost_in_usd_ticks, which is divided by 1e10
 *   - OpenRouter adds usage.cost
 *   - DeepSeek uses prompt_cache_hit/miss_tokens instead of cached_tokens
 */
function pickUsageParser(providerKind: string | undefined): (
  usage: Record<string, unknown>,
) => UsageBreakdown {
  switch (providerKind) {
    case 'openAI':
      return parseUsageOpenAI;
    case 'openRouter':
      return parseUsageOpenRouter;
    case 'grok':
      return parseUsageGrok;
    case 'deepseek':
      return parseUsageDeepSeek;
    case 'moonshot':
      return parseUsageMoonshot;
    // Groq / Fireworks / MiniMax / Zhipu / SiliconFlow / Together / Mistral / Relay all parse
    // with the OpenAI-compatible template, cached_tokens fallback included. Mistral's
    // prompt_tokens_details.cached_tokens has the same shape as OpenAI's (verified 2026-07).
    default:
      return parseUsageOpenAICompatible;
  }
}

interface OpenAIChatChunk {
  choices?: Array<{
    delta?: {
      // Mistral Magistral and similar models turn delta.content into an array of blocks
      // (thinking/text) while reasoning; see content-block-parser.ts. Everything else sends a
      // plain string.
      content?: string | unknown[];
      reasoning_content?: string;
      // Groq / Together (gpt-oss) / OpenRouter use `reasoning`, without the _content suffix
      reasoning?: string;
      annotations?: Array<Record<string, unknown>>;
      tool_calls?: Array<Record<string, unknown>>;
      images?: Array<{ image_url?: { url?: string } }>;
    };
    message?: {
      annotations?: Array<Record<string, unknown>>;
    };
  }>;
  /** Raw upstream usage payload; the field set varies by provider, so pickUsageParser routes it. */
  usage?: Record<string, unknown>;
}

function convertContentParts(parts: ContentPart[]): unknown[] {
  return parts.map((p) => {
    if (p.type === 'text') return p;
    if (p.type === 'image_url') {
      // image_url may carry detail ('auto'/'low'/'high'), passed straight through to OpenAI
      // Chat Completions; chat-stream-utils fills in 'auto' by default.
      return p;
    }
    if (p.type === 'video_url') return p;
    if (p.type === 'file') {
      // openai-chat has no native file part: route=native requests belong on openai-responses.
      // This is only a fallback, since the router already keeps file parts off chat-completions.
      return { type: 'text' as const, text: `[File: ${p.file.filename}]` };
    }
    return { type: 'text' as const, text: '[unsupported]' };
  });
}

// Relay is the one heuristic exception: a user-supplied OpenAI-compatible endpoint has no official profile to consult.
function relayOpenAIEffort(mode: string): 'low' | 'medium' | 'high' {
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

function emitAnnotationCitations(
  annotations: unknown,
  ctx: StreamContext,
  shape: StreamShape | null,
): boolean {
  if (!Array.isArray(annotations)) return false;
  let changed = false;
  for (const raw of annotations) {
    if (!raw || typeof raw !== 'object') continue;
    const item = raw as Record<string, unknown>;
    // OpenAI Responses style: `type: "url_citation"` plus `url_citation: { url, title, ... }`
    if (item.type === 'url_citation' && item.url_citation && typeof item.url_citation === 'object') {
      const c = citationFromRaw(item.url_citation, shape, {
        urlField: 'url',
        titleField: 'title',
        snippetField: 'snippet',
      });
      if (mergeCitation(ctx.citations, c)) changed = true;
      continue;
    }
    // Flat style: the entry is directly { url, title, snippet, ... }
    const c = citationFromRaw(item, shape, {
      urlField: 'url',
      titleField: 'title',
      snippetField: 'snippet',
    });
    if (mergeCitation(ctx.citations, c)) changed = true;
  }
  return changed;
}

export const openAIChatStrategy: TransportStrategy = {
  kind: 'openai_chat',
  buildRequestBody(input: BuildRequestInput): Record<string, unknown> {
    const apiMessages = input.messages.map((m) => ({
      role: m.role,
      content: typeof m.content === 'string' ? m.content : convertContentParts(m.content),
    }));
    const body: Record<string, unknown> = {
      model: input.modelID,
      stream: true,
      stream_options: { include_usage: true },
      messages: apiMessages,
    };
    // Reasoning for official providers is always injected from the metadata profile's
    // params[level]; the local level mapping is a relay-only exception, because a user-supplied
    // endpoint has no catalog to look up. This mirrors the useRelayFallbacks gate in
    // gemini-generate: without it, an official provider that switched to direct browser calls
    // would silently use the local mapping against an official upstream, which clients must
    // never do.
    if (
      input.providerKind === 'relay' &&
      input.options?.reasoning &&
      input.options.reasoning !== 'automatic'
    ) {
      body.reasoning_effort = relayOpenAIEffort(input.options.reasoning);
    }
    if (input.mergeParams) deepMerge(body, input.mergeParams);
    return body;
  },
  parseStreamChunk(_eventType, data, ctx, shape) {
    const chunk: OpenAIChatChunk = JSON.parse(data);
    const events: StreamEvent[] = [];

    if (chunk.usage) {
      const breakdown = pickUsageParser(ctx.providerKind)(chunk.usage);
      events.push({
        type: 'usage',
        usage: {
          prompt_tokens:
            typeof chunk.usage.prompt_tokens === 'number' ? chunk.usage.prompt_tokens : undefined,
          completion_tokens:
            typeof chunk.usage.completion_tokens === 'number' ? chunk.usage.completion_tokens : undefined,
          total_tokens:
            typeof chunk.usage.total_tokens === 'number' ? chunk.usage.total_tokens : undefined,
          breakdown,
        },
      });
    }

    const choice = chunk.choices?.[0];
    const delta = choice?.delta;
    events.push(...nativeToolCallEvents('openai_chat', _eventType, chunk as unknown as Record<string, unknown>, ctx.state));
    if (Array.isArray(delta?.content)) {
      // Block-array content, as used by the Mistral Magistral thinking protocol: thinking
      // becomes reasoning and text becomes delta. Provider agnostic, so a relay pointing at the
      // same protocol works too.
      events.push(...parseContentBlockArray(delta.content));
    } else if (delta?.content) {
      if (ctx.providerKind === 'miniMax') {
        events.push(...parseThinkingTaggedDelta(delta.content, getThinkingTagState(ctx)));
      } else {
        events.push({ type: 'delta', content: delta.content });
      }
    }
    // Some OpenAI-compatible services (Groq, Together gpt-oss, OpenRouter) put the reasoning
    // delta in delta.reasoning, without the _content suffix, so check both.
    const reasoningChunk = delta?.reasoning_content ?? delta?.reasoning;
    // Empty strings are kept: an upstream emitting reasoning_content:"" while it thinks is the
    // only "still working" signal available, and dropping it leaves the UI with nothing but a
    // spinner (DeepSeek took 279s to emit its first non-empty reasoning chunk in 2026-08).
    if (typeof reasoningChunk === 'string') {
      events.push({ type: 'reasoning', content: reasoningChunk });
    }
    if (delta?.images) {
      for (const img of delta.images) {
        if (img.image_url?.url) events.push({ type: 'image', url: img.image_url.url });
      }
    }

    // Citations: prefer the path named by streamShape, as Zhipu needs
    const overridePath = shape?.citationsArrayPath;
    let citationChanged = false;
    let overrideHadEntries = false;
    if (overridePath) {
      const arr = readPath(chunk, overridePath);
      if (Array.isArray(arr) && arr.length > 0) {
        overrideHadEntries = true;
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
    // Fall back to the default annotations path when the override is missing or empty on this chunk
    if (!overrideHadEntries) {
      if (emitAnnotationCitations(delta?.annotations, ctx, shape)) citationChanged = true;
      if (emitAnnotationCitations(choice?.message?.annotations, ctx, shape)) citationChanged = true;
    }
    if (citationChanged) {
      events.push({ type: 'citations', citations: ctx.citations.slice() });
    }
    if (ctx.providerKind === 'miniMax' && choice && !delta?.content) {
      events.push(...parseThinkingTaggedDelta('', getThinkingTagState(ctx), { final: true }));
    }

    return events.length > 0 ? events : null;
  },
  parseError(status, body) {
    return { message: parseOpenAIErrorMessage(body) || `HTTP ${status}` };
  },
};

function getThinkingTagState(ctx: StreamContext): ThinkingTagParserState {
  const key = 'thinkingTagParser';
  const existing = ctx.state[key];
  if (existing && typeof existing === 'object') {
    return existing as ThinkingTagParserState;
  }
  const created = createThinkingTagParserState();
  ctx.state[key] = created;
  return created;
}

function parseOpenAIErrorMessage(body: unknown): string {
  if (!body) return '';
  if (typeof body === 'string') return body;
  if (typeof body === 'object') {
    const err = (body as { error?: unknown }).error;
    if (typeof err === 'string') return err;
    if (err && typeof err === 'object') {
      const msg = (err as { message?: unknown }).message;
      if (typeof msg === 'string') return msg;
    }
    const msg = (body as { message?: unknown }).message;
    if (typeof msg === 'string') return msg;
  }
  return '';
}
