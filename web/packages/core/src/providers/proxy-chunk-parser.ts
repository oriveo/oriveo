/**
 * Unified parser turning proxied SSE chunks into StreamEvent values.
 *
 * The browser renderer and the desktop main process share this one decoder:
 *   - Browser: `sendStreamProxy` takes the raw SSE from `/api/chat/stream` and decodes it here.
 *   - Desktop main: executeProviderRequest decodes the upstream SSE in the main process and
 *     forwards StreamEvent values to the renderer over a MessagePort.
 *
 * Covers unified proxy events, OpenAI(-compatible), Anthropic (cross-frame usage merge plus
 * cache breakdown), Gemini (content blocking) and OpenAI Responses (web citation accumulation
 * plus images).
 */

import type { Citation, ProviderKind } from '@oriveo/shared/pure-types';
import type {
  StreamEvent,
  StreamToolCallDelta,
  StreamUsage,
  ToolConfirmationReason,
} from './types';
import { nativeToolCallEvents } from './tool-call-protocol';
import { isMiniMaxAnthropicReplayBlocks, validateContinuation, type ContinuationIntent } from './request-preference/continuation';
import type { ParseChunkFn } from './sse-parser';
import { detectGeminiBlockEvent } from './transport/strategies/gemini-generate';
import { mergeCitation } from './transport/citation-utils';
import { parseContentBlockArray } from './transport/content-block-parser';
import type { UsageBreakdown } from '../chat/usage-breakdown';
import {
  normalizeResponsesUsage,
  parseUsageAnthropic,
  parseUsageDeepSeek,
  parseUsageGemini,
  parseUsageGrok,
  parseUsageMoonshot,
  parseUsageOpenAI,
  parseUsageOpenAICompatible,
  parseUsageOpenRouter,
  parseUsageQwen,
} from './transport/usage-parsers';

export interface ContinuationCaptureConfig {
  kind: string;
  protocol: string;
  responseParserKind: string;
}

/**
 * Pick the UsageBreakdown parser for a providerKind, matching pickUsageParser in
 * transport/strategies/openai-chat.ts. In the browser USE_PROXY is always true and official
 * providers all go through parseProxyChunk, so the cache-discount breakdown has to be built
 * here or deriveCostFields falls back to an estimate and the discount is lost.
 */
export function pickProxyUsageParser(
  providerKind: string | undefined,
): (usage: Record<string, unknown>) => UsageBreakdown {
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
    // Qwen's `cached_tokens` path varies by region: Singapore nests it under
    // `prompt_tokens_details`, while some Beijing models (qwen3-vl-plus) put it at the top level
    // of usage. The OpenAI template only reads the former, so the latter would be silently
    // treated as unobserved and the cache card would disappear.
    case 'qwen':
      return parseUsageQwen;
    // Groq / Fireworks / MiniMax / Zhipu / SiliconFlow / Together / Mistral / Relay
    // all parse with the OpenAI-compatible template, including the cached_tokens fallback;
    // Mistral's prompt_tokens_details.cached_tokens matches the OpenAI shape (verified
    // 2026-07-21). Anthropic and Gemini never reach here: they have their own chunk branches
    // calling dedicated parsers. A new providerKind would silently land on this default, so
    // usage-parser-routing.test.ts pins every kind in PROVIDER_KINDS and fails on a gap.
    default:
      return parseUsageOpenAICompatible;
  }
}

/**
 * Create a parseChunk closure holding per-stream state.
 *
 * Anthropic reports input_tokens only in message_start and output_tokens only in message_delta,
 * never in the same frame, and readStream's last-wins usage merge would drop the input side and
 * leave prompt cost at 0. So the parser is a factory: every stream gets its own instance, caches
 * the full message_start usage in the closure, and merges output_tokens in at message_delta
 * before computing the breakdown.
 *
 * A stateless singleton would let concurrent streams pollute each other, hence the per-stream
 * instance. Other providers do not read the closure state and keep last-wins usage.
 */
export function createProxyChunkParser(providerKind?: ProviderKind, continuationCapture?: ContinuationCaptureConfig): ParseChunkFn {
  // Full Anthropic message_start usage (including nested cache_read / cache_creation) plus input_tokens.
  let anthropicUsage: Record<string, unknown> | undefined;
  let anthropicInputTokens = 0;
  // Accumulated url_citation annotations for OpenAI/Grok Responses web search. Annotations arrive
  // one at a time, so the closure accumulates across chunks and emits a full snapshot whenever
  // something is added or updated (mergeCitation handles deduplication).
  const responsesCitations: Citation[] = [];
  // Anthropic web-result, Gemini grounding and OpenRouter citations are normalized by this same
  // parser, but must not be mixed with the Responses annotation stream.
  const protocolCitations: Citation[] = [];
  const pickUsage = pickProxyUsageParser(providerKind);
  // /api/chat/stream only forwards for BYOK providers, so ownership of in-stream provider errors
  // has to be pinned at this single parsing entry point rather than guessed at the reporting layer.
  const upstreamErrorSource = 'provider';
  const captureContinuation = createRecipeContinuationCapture(continuationCapture);
  const miniMaxAnthropicWeb = continuationCapture?.protocol === 'anthropic_messages'
    && continuationCapture.responseParserKind === 'minimax_anthropic_web_v1';
  const nativeToolCallState: Record<string, unknown> = {};

  return (_eventType, data) => {
    const chunk = JSON.parse(data);
    const events: StreamEvent[] = [];

    // Unified proxy event format
    if (chunk.type === 'delta' && typeof chunk.content === 'string') {
      events.push({ type: 'delta', content: chunk.content });
    }
    if (chunk.type === 'image' && typeof chunk.url === 'string') {
      events.push({ type: 'image', url: chunk.url });
    }
    // The MiniMax adapter normalizes the <think> text protocol into unified reasoning/model events (minimax-chat.ts).
    if (chunk.type === 'reasoning' && typeof chunk.content === 'string' && chunk.content) {
      events.push({ type: 'reasoning', content: chunk.content });
    }
    if (chunk.type === 'model' && typeof chunk.modelID === 'string' && chunk.modelID) {
      events.push({ type: 'model', modelID: chunk.modelID });
    }
    if (chunk.type === 'usage' && chunk.usage) {
      events.push({ type: 'usage', usage: buildUsageEvent(chunk.usage, pickUsage) });
    }
    if (chunk.type === 'error' && typeof chunk.error === 'string') {
      events.push({
        type: 'error',
        error: chunk.error,
        errorKind: chunk.errorKind,
        source: isProviderErrorSource(chunk.source) ? chunk.source : upstreamErrorSource,
      });
    }
    if (chunk.type === 'tool_calls') {
      const toolCalls = parseToolCallDeltas(chunk.toolCalls ?? chunk.tool_calls);
      if (toolCalls.length > 0) events.push({ type: 'tool_calls', toolCalls });
    }
    if (chunk.type === 'continuation' && isRecord(chunk.continuation)) {
      const continuation = chunk.continuation as ContinuationIntent;
      if (typeof continuation.kind === 'string'
        && (continuation.variant === undefined || typeof continuation.variant === 'string')
        && typeof continuation.step === 'number'
        && isRecord(continuation.state)
        && validateContinuation(continuation).accepted) {
        events.push({ type: 'continuation', continuation });
      }
    }
    if (
      chunk.type === 'tool_call'
      && isNonEmptyString(chunk.tool)
      && isRecord(chunk.args)
      && isStep(chunk.step)
    ) {
      events.push({ type: 'tool_call', tool: chunk.tool, args: chunk.args, step: chunk.step });
    }
    if (
      chunk.type === 'tool_result'
      && isNonEmptyString(chunk.tool)
      && typeof chunk.summary === 'string'
      && isStep(chunk.step)
    ) {
      events.push({
        type: 'tool_result',
        tool: chunk.tool,
        summary: chunk.summary,
        step: chunk.step,
      });
    }
    if (
      chunk.type === 'confirm_required'
      && isToolConfirmationReason(chunk.reason)
      && isRecord(chunk.detail)
    ) {
      events.push({
        type: 'confirm_required',
        reason: chunk.reason,
        detail: chunk.detail,
      });
    }

    // OpenAI/OpenRouter format
    if (!_eventType && chunk.usage) {
      events.push({ type: 'usage', usage: buildUsageEvent(chunk.usage, pickUsage) });
    }
    if (!_eventType && chunk.model) {
      events.push({ type: 'model', modelID: chunk.model });
    }
    // OpenAI-style in-stream error blocks: DashScope-compatible endpoints put {"error":{message}}
    // inside a 200 stream, or a top-level {"code","message"}. Surface the real reason instead of
    // silently swallowing it as an empty response.
    if (!_eventType && chunk.error) {
      const msg = typeof chunk.error === 'string'
        ? chunk.error
        : (chunk.error?.message ?? 'Provider error');
      events.push({ type: 'error', error: msg, errorKind: 'upstream', source: upstreamErrorSource });
    } else if (!_eventType && chunk.code && typeof chunk.message === 'string' && !chunk.choices) {
      events.push({ type: 'error', error: chunk.message, errorKind: 'upstream', source: upstreamErrorSource });
    }
    const choice = !_eventType ? chunk.choices?.[0] : undefined;
    events.push(...nativeToolCallEvents('openai_chat', _eventType, chunk, nativeToolCallState));
    const content = choice?.delta?.content ?? choice?.message?.content;
    // Groq / Together (gpt-oss) / OpenRouter put reasoning deltas in reasoning (no _content suffix), so check both.
    const reasoningContent =
      choice?.delta?.reasoning_content
      ?? choice?.delta?.reasoning
      ?? choice?.message?.reasoning_content
      ?? choice?.message?.reasoning;
    // Empty strings are not dropped: upstreams such as DeepSeek emit reasoning_content:"" as a
    // heartbeat while thinking and only flush the real text once the whole block is done (first
    // non-empty reasoning observed at 279s on 2026-08-07). Dropping the heartbeat leaves the UI
    // silent for minutes, so users cannot tell thinking from a hang. A missing field still never
    // reaches here.
    if (typeof reasoningContent === 'string') {
      events.push({ type: 'reasoning', content: reasoningContent });
    }
    if (content) {
      if (typeof content === 'string') {
        events.push({ type: 'delta', content });
      } else if (Array.isArray(content)) {
        // Block arrays all go through content-block-parser: text/image_url behave as before, and
        // thinking blocks (the Mistral Magistral reasoning protocol) become reasoning deltas.
        // Streaming and non-streaming (delta.content / message.content) share this entry point.
        events.push(...parseContentBlockArray(content));
      }
    }
    // OpenRouter image data: delta.images or message.images
    const images = choice?.delta?.images ?? choice?.message?.images;
    if (images) {
      for (const img of images) {
        if (img.image_url?.url) events.push({ type: 'image', url: img.image_url.url });
      }
    }

    // Anthropic format.
    // message_start: cache input_tokens and the full usage object so message_delta can merge in
    // output_tokens and compute the breakdown.
    if (chunk.type === 'message_start') {
      const usage = (chunk.message?.usage ?? {}) as Record<string, unknown>;
      anthropicUsage = usage;
      anthropicInputTokens = typeof usage.input_tokens === 'number' ? usage.input_tokens : 0;
    }
    if (chunk.type === 'content_block_delta') {
      const delta = chunk.delta;
      if (delta?.type === 'text_delta' && typeof delta.text === 'string' && delta.text) {
        events.push({ type: 'delta', content: delta.text });
      } else if (
        delta?.type === 'thinking_delta'
        && typeof delta.thinking === 'string'
        && delta.thinking
      ) {
        // Extended thinking delta: billed, and the UI renders it as a ReasoningBlock.
        events.push({ type: 'reasoning', content: delta.thinking });
      } else if (typeof delta?.text === 'string' && delta.text) {
        // Fallback for the older shape with no delta.type but a text field.
        events.push({ type: 'delta', content: delta.text });
      }
    }
    events.push(...nativeToolCallEvents('anthropic_messages', _eventType, chunk));
    if ((providerKind === 'anthropic' || miniMaxAnthropicWeb)
      && chunk.type === 'content_block_start' && isRecord(chunk.content_block)) {
      const block = chunk.content_block;
      if (block.type === 'web_search_tool_result' && Array.isArray(block.content)) {
        let changed = false;
        const summaries: string[] = [];
        for (const item of block.content) {
          if (!isRecord(item) || typeof item.url !== 'string') continue;
          summaries.push(typeof item.title === 'string' && item.title ? item.title : item.url);
          changed = mergeCitation(protocolCitations, {
            url: item.url,
            title: typeof item.title === 'string' ? item.title : undefined,
            snippet: typeof (miniMaxAnthropicWeb ? item.content : item.cited_text) === 'string'
              ? miniMaxAnthropicWeb ? item.content as string : item.cited_text as string
              : undefined,
          }) || changed;
        }
        if (changed) events.push({ type: 'citations', citations: protocolCitations.slice() });
        if (miniMaxAnthropicWeb && summaries.length > 0) {
          events.push({
            type: 'tool_result', tool: 'web_search', summary: summaries.join(' - '),
            step: Number.isInteger(chunk.index) && chunk.index >= 0 ? chunk.index : 0,
          });
        }
      }
    }
    if (chunk.type === 'message_delta' && chunk.usage) {
      const outputTokens =
        typeof chunk.usage.output_tokens === 'number' ? chunk.usage.output_tokens : 0;
      // Merge the usage cached at message_start (including cache_read / cache_creation) with this frame's output_tokens.
      const merged: Record<string, unknown> = {
        ...(anthropicUsage ?? {}),
        output_tokens: outputTokens,
      };
      const breakdown = parseUsageAnthropic(merged);
      events.push({
        type: 'usage',
        usage: {
          prompt_tokens: anthropicInputTokens,
          completion_tokens: outputTokens,
          total_tokens: anthropicInputTokens + outputTokens,
          breakdown,
        },
      });
    }
    // Anthropic in-stream event:error (mid-response moderation or overload), shaped as
    // event:error + data:{type:error,error:{type,message}}. Neither the unified branch (error must
    // be a string) nor the OpenAI branch (requires !_eventType) matches, so without this it would
    // evaporate into a truncated empty response.
    if (_eventType === 'error' && chunk.error && typeof chunk.error === 'object') {
      const msg =
        typeof chunk.error.message === 'string' && chunk.error.message
          ? chunk.error.message
          : 'Provider error';
      events.push({ type: 'error', error: msg, errorKind: 'upstream', source: upstreamErrorSource });
    }
    if (!_eventType && (providerKind === 'anthropic' || miniMaxAnthropicWeb)
      && chunk.type === 'message' && Array.isArray(chunk.content)) {
      for (const [index, block] of chunk.content.entries()) {
        if (!isRecord(block)) continue;
        if (block.type === 'text' && typeof block.text === 'string') events.push({ type: 'delta', content: block.text });
        if (block.type === 'thinking' && typeof block.thinking === 'string') events.push({ type: 'reasoning', content: block.thinking });
        if (block.type === 'tool_use' && typeof block.id === 'string' && typeof block.name === 'string' && isRecord(block.input)) {
          events.push({ type: 'tool_calls', toolCalls: [{
            index, id: block.id, type: 'function', name: block.name, arguments: JSON.stringify(block.input),
          }] });
        }
        if (block.type === 'web_search_tool_result' && Array.isArray(block.content)) {
          let changed = false;
          const summaries: string[] = [];
          for (const item of block.content) {
            if (!isRecord(item) || typeof item.url !== 'string') continue;
            summaries.push(typeof item.title === 'string' && item.title ? item.title : item.url);
            changed = mergeCitation(protocolCitations, {
              url: item.url,
              title: typeof item.title === 'string' ? item.title : undefined,
              snippet: typeof (miniMaxAnthropicWeb ? item.content : item.cited_text) === 'string'
                ? miniMaxAnthropicWeb ? item.content as string : item.cited_text as string
                : undefined,
            }) || changed;
          }
          if (changed) events.push({ type: 'citations', citations: protocolCitations.slice() });
          if (miniMaxAnthropicWeb && summaries.length > 0) {
            events.push({ type: 'tool_result', tool: 'web_search', summary: summaries.join(' - '), step: index });
          }
        }
      }
    }

    // Gemini format.
    // Content blocking (promptFeedback.blockReason or a policy finishReason) arrives as fields
    // inside a 200 stream; on a match the rest of the chunk (parts/usage) is discarded, matching
    // the direct-connection strategy. A top-level {"error":{...}} chunk is already handled by the
    // OpenAI-style in-stream error branch above, since Gemini uses the same shape.
    const geminiBlocked = detectGeminiBlockEvent(chunk);
    if (geminiBlocked) {
      events.push({ ...geminiBlocked, source: upstreamErrorSource });
      return events;
    }
    const parts = chunk.candidates?.[0]?.content?.parts;
    if (parts) {
      for (const part of parts) {
        if (part.text) {
          events.push({ type: 'delta', content: part.text });
        }
      }
    }
    events.push(...nativeToolCallEvents('gemini_generate_content', _eventType, chunk));
    if (chunk.usageMetadata) {
      events.push({
        type: 'usage',
        usage: {
          prompt_tokens: chunk.usageMetadata.promptTokenCount || 0,
          completion_tokens: chunk.usageMetadata.candidatesTokenCount || 0,
          total_tokens: chunk.usageMetadata.totalTokenCount || 0,
          breakdown: parseUsageGemini(chunk.usageMetadata),
        },
      });
    }
    if (providerKind === 'gemini' && Array.isArray(chunk.candidates?.[0]?.groundingMetadata?.groundingChunks)) {
      let changed = false;
      for (const raw of chunk.candidates[0].groundingMetadata.groundingChunks) {
        const web = isRecord(raw) && isRecord(raw.web) ? raw.web : null;
        if (!web || typeof web.uri !== 'string') continue;
        changed = mergeCitation(protocolCitations, {
          url: web.uri,
          title: typeof web.title === 'string' ? web.title : undefined,
        }) || changed;
      }
      if (changed) events.push({ type: 'citations', citations: protocolCitations.slice() });
    }
    if (providerKind === 'openRouter' && Array.isArray(chunk.citations)) {
      let changed = false;
      for (const raw of chunk.citations) {
        if (!isRecord(raw) || typeof raw.url !== 'string') continue;
        changed = mergeCitation(protocolCitations, {
          url: raw.url,
          title: typeof raw.title === 'string' ? raw.title : undefined,
          snippet: typeof raw.snippet === 'string' ? raw.snippet : undefined,
        }) || changed;
      }
      if (changed) events.push({ type: 'citations', citations: protocolCitations.slice() });
    }

    // OpenAI Responses SSE
    if (!_eventType && (providerKind === 'openAI' || providerKind === 'grok') && Array.isArray(chunk.output)) {
      for (const item of chunk.output) {
        if (!isRecord(item) || item.type !== 'message' || !Array.isArray(item.content)) continue;
        for (const block of item.content) {
          if (isRecord(block) && block.type === 'output_text' && typeof block.text === 'string') {
            events.push({ type: 'delta', content: block.text });
          }
        }
      }
    }
    if (_eventType === 'response.output_text.delta' && typeof chunk.delta === 'string') {
      events.push({ type: 'delta', content: chunk.delta });
    }
    events.push(...nativeToolCallEvents('openai_responses', _eventType, chunk));
    // Reasoning summary deltas: gpt-5 and the o-series actually emit
    // response.reasoning_summary_text.delta, while other variants send response.reasoning.delta or
    // response.reasoning_summary.delta, so all three are covered.
    if (
      (_eventType === 'response.reasoning_summary_text.delta' ||
        _eventType === 'response.reasoning.delta' ||
        _eventType === 'response.reasoning_summary.delta') &&
      typeof chunk.delta === 'string' &&
      chunk.delta
    ) {
      events.push({ type: 'reasoning', content: chunk.delta });
    }
    // Web search url_citation annotations (OpenAI and Grok Responses share the shape, with both
    // annotation.added and annotations.added variants): accumulate and deduplicate, then emit a
    // full snapshot, using the same mergeCitation mapping as the openai-responses strategy.
    if (
      _eventType === 'response.output_text.annotation.added' ||
      _eventType === 'response.output_text.annotations.added'
    ) {
      const ann = chunk.annotation as Record<string, unknown> | undefined;
      if (ann && ann.type === 'url_citation') {
        const changed = mergeCitation(responsesCitations, {
          url: typeof ann.url === 'string' ? ann.url : '',
          title: typeof ann.title === 'string' ? ann.title : undefined,
          startIndex: typeof ann.start_index === 'number' ? ann.start_index : undefined,
          endIndex: typeof ann.end_index === 'number' ? ann.end_index : undefined,
        });
        if (changed) {
          events.push({ type: 'citations', citations: responsesCitations.slice() });
        }
      }
    }
    if (
      (_eventType === 'response.output_image.done' || _eventType === 'response.image_generation_call.completed')
      && typeof chunk.result === 'string'
    ) {
      events.push({
        type: 'image',
        url: chunk.result.startsWith('data:') ? chunk.result : `data:image/png;base64,${chunk.result}`,
      });
    }
    const responsesUsage = chunk.usage ?? chunk.response?.usage;
    if (_eventType === 'response.completed' && responsesUsage) {
      // Responses and Chat Completions have the same usage semantics but different paths: the
      // details live under `input_tokens_details` / `output_tokens_details`. Normalize first, then
      // hand off to the parser for the providerKind. Renaming only the top-level fields is not
      // enough:
      //   - openAI happens to get the totals right via parseUsageOpenAI's `?? input_tokens`, but
      //     cache reads and reasoning stay 0 and cacheReadObserved stays false;
      //   - grok uses parseUsageGrok, which has no input_tokens fallback, so the whole usage object
      //     zeroes out (Grok really does go through /responses, see request-builders/grok.ts).
      const normalized = normalizeResponsesUsage(responsesUsage);
      const inputTokens = typeof normalized.prompt_tokens === 'number' ? normalized.prompt_tokens : 0;
      const outputTokens = typeof normalized.completion_tokens === 'number' ? normalized.completion_tokens : 0;
      events.push({
        type: 'usage',
        usage: {
          prompt_tokens: inputTokens,
          completion_tokens: outputTokens,
          // The Responses envelope does not always carry total_tokens, so fall back to
          // input + output rather than passing undefined through to existing consumers.
          total_tokens:
            typeof normalized.total_tokens === 'number'
              ? normalized.total_tokens
              : inputTokens + outputTokens,
          breakdown: pickUsage(normalized),
        },
      });
    }
    if (_eventType === 'response.failed') {
      const error = resolveResponseStreamError(chunk);
      events.push({ type: 'error', error, errorKind: 'upstream', source: upstreamErrorSource });
    }

    events.push(...captureContinuation(_eventType, chunk));

    return events.length > 0 ? events : null;
  };
}

type RecipeCapture = (eventType: string | null, chunk: Record<string, any>) => StreamEvent[];

/** Continuation producer. Selection is supplied by the authoritative runtime recipe; this parser
 * never guesses from model IDs. It extracts only the protocol-owned opaque state a later explicit
 * continue needs, and leaves observed capability evidence to the evidence collector. */
function createRecipeContinuationCapture(config: ContinuationCaptureConfig | undefined): RecipeCapture {
  if (!config) return () => [];
  if (config.kind === 'previous_id'
    && config.protocol === 'openai_responses'
    && ['openai_responses_web_v1', 'openai_responses_reasoning_v1', 'grok_web_search_v1', 'grok_reasoning_v1'].includes(config.responseParserKind)) {
    let emittedID: string | undefined;
    return (eventType, chunk) => {
      const response = isRecord(chunk.response) ? chunk.response : chunk;
      const completed = eventType === 'response.completed' || eventType === 'response.done'
        || (eventType == null && response.status === 'completed');
      const id = typeof response.id === 'string' ? response.id : undefined;
      if (!completed || !id || id === emittedID) return [];
      emittedID = id;
      return continuationEvents({ kind: 'previous_id', step: 1, state: { previousResponseId: id } });
    };
  }
  if (config.kind === 'replay_blocks'
    && config.protocol === 'anthropic_messages'
    && ['anthropic_web_search_v1', 'anthropic_thinking_v1', 'minimax_anthropic_web_v1'].includes(config.responseParserKind)) {
    return createAnthropicReplayCapture(config.responseParserKind === 'minimax_anthropic_web_v1');
  }
  if (config.kind === 'replay_blocks'
    && config.protocol === 'gemini_generate_content'
    && ['gemini_google_search_v1', 'gemini_thinking_v1'].includes(config.responseParserKind)) {
    return createGeminiReplayCapture();
  }
  if (config.kind === 'replay_reasoning' && config.protocol === 'openai_chat'
    && ['openrouter_reasoning_v1', 'moonshot_reasoning_v1', 'deepseek_reasoning_v1', 'mistral_reasoning_v1', 'minimax_reasoning_v1'].includes(config.responseParserKind)) {
    if (config.responseParserKind === 'mistral_reasoning_v1') return createMistralReasoningCapture();
    if (config.responseParserKind === 'minimax_reasoning_v1') return createMiniMaxReasoningCapture();
    return createOpenAIChatReasoningCapture(config.responseParserKind);
  }
  return () => [];
}

function createMiniMaxReasoningCapture(): RecipeCapture {
  let content: string | null = null;
  let contentSeen = false;
  let invalid = false;
  const reasoningDetails = new Map<number, Record<string, unknown>>();
  const toolCalls = new Map<number, { id?: string; type?: string; name?: string; arguments: string }>();
  const reset = () => {
    content = null;
    contentSeen = false;
    invalid = false;
    reasoningDetails.clear();
    toolCalls.clear();
  };
  return (_eventType, chunk) => {
    const choice = Array.isArray(chunk.choices) && isRecord(chunk.choices[0]) ? chunk.choices[0] : null;
    if (!choice) return [];
    const message = isRecord(choice.message) ? choice.message : null;
    const fragment = isRecord(choice.delta) ? choice.delta : message;
    if (fragment) {
      if (Object.hasOwn(fragment, 'content')) {
        if (message) {
          if (typeof fragment.content === 'string' || fragment.content === null) {
            content = fragment.content;
            contentSeen = true;
          } else invalid = true;
        } else if (typeof fragment.content === 'string') {
          content = `${content ?? ''}${fragment.content}`;
          contentSeen = true;
        } else if (fragment.content !== null) invalid = true;
      }
      if (Object.hasOwn(fragment, 'reasoning_details')) {
        if (!Array.isArray(fragment.reasoning_details)
          || !mergeStrictReasoningDetails(reasoningDetails, fragment.reasoning_details)) invalid = true;
      }
      if (Object.hasOwn(fragment, 'tool_calls')) {
        if (!Array.isArray(fragment.tool_calls)
          || !mergeStrictAssistantToolCalls(toolCalls, fragment.tool_calls)) invalid = true;
      }
    }
    if (!message && choice.finish_reason == null) return [];
    if (invalid || !contentSeen || reasoningDetails.size === 0) {
      reset();
      return [];
    }
    const assistant: Record<string, unknown> = {
      role: 'assistant',
      content,
      reasoning_details: [...reasoningDetails.entries()]
        .sort(([left], [right]) => left - right)
        .map(([, detail]) => detail),
    };
    if (toolCalls.size > 0) {
      const completeCalls = finalizedAssistantToolCalls(toolCalls);
      if (!completeCalls) {
        reset();
        return [];
      }
      assistant.tool_calls = completeCalls;
    }
    reset();
    return continuationEvents({
      kind: 'replay_reasoning', step: 1, state: { assistantMessages: [assistant] },
    });
  };
}

function createAnthropicReplayCapture(strictMiniMax = false): RecipeCapture {
  const blocks = new Map<number, Record<string, unknown>>();
  const partialInputs = new Map<number, string>();
  let invalid = false;
  const reset = () => {
    blocks.clear();
    partialInputs.clear();
    invalid = false;
  };
  return (eventType, chunk) => {
    const type = eventType ?? (typeof chunk.type === 'string' ? chunk.type : null);
    if (eventType == null && chunk.type === 'message' && Array.isArray(chunk.content)) {
      const complete = cloneJson(chunk.content);
      return !strictMiniMax || isMiniMaxAnthropicReplayBlocks(complete)
        ? continuationEvents({ kind: 'replay_blocks', step: 1, state: { blocks: complete } })
        : [];
    }
    const index = Number.isInteger(chunk.index) && chunk.index >= 0 ? chunk.index : -1;
    if (type === 'content_block_start' && index >= 0 && isRecord(chunk.content_block)) {
      blocks.set(index, cloneJson(chunk.content_block));
    } else if (type === 'content_block_delta' && index >= 0 && isRecord(chunk.delta)) {
      const block = blocks.get(index);
      if (!block) return [];
      const delta = chunk.delta;
      if (delta.type === 'thinking_delta' && typeof delta.thinking === 'string') appendString(block, 'thinking', delta.thinking);
      else if (delta.type === 'signature_delta' && typeof delta.signature === 'string') appendString(block, 'signature', delta.signature);
      else if (delta.type === 'text_delta' && typeof delta.text === 'string') appendString(block, 'text', delta.text);
      else if (delta.type === 'input_json_delta' && typeof delta.partial_json === 'string') {
        partialInputs.set(index, `${partialInputs.get(index) ?? ''}${delta.partial_json}`);
      } else if (strictMiniMax) invalid = true;
    } else if (strictMiniMax && (type === 'content_block_start' || type === 'content_block_delta')) {
      invalid = true;
    }
    if (type !== 'message_stop') return [];
    for (const [blockIndex, raw] of partialInputs) {
      const block = blocks.get(blockIndex);
      if (!block) continue;
      try { block.input = JSON.parse(raw); } catch { reset(); return []; }
    }
    const complete = [...blocks.entries()].sort(([a], [b]) => a - b).map(([, block]) => block);
    const accepted = !invalid && (!strictMiniMax || isMiniMaxAnthropicReplayBlocks(complete));
    reset();
    return accepted && complete.length > 0
      ? continuationEvents({ kind: 'replay_blocks', step: 1, state: { blocks: complete } })
      : [];
  };
}

function createGeminiReplayCapture(): RecipeCapture {
  let role = 'model';
  let parts: unknown[] = [];
  return (_eventType, chunk) => {
    const candidate = Array.isArray(chunk.candidates) && isRecord(chunk.candidates[0]) ? chunk.candidates[0] : null;
    const content = candidate && isRecord(candidate.content) ? candidate.content : null;
    if (content) {
      if (content.role === 'model') role = 'model';
      if (Array.isArray(content.parts)) parts.push(...cloneJson(content.parts));
    }
    if (!candidate || typeof candidate.finishReason !== 'string') return [];
    const complete = parts;
    parts = [];
    return complete.length > 0
      ? continuationEvents({ kind: 'replay_blocks', step: 1, state: { blocks: [{ role, parts: complete }] } })
      : [];
  };
}

function createOpenAIChatReasoningCapture(responseParserKind: string): RecipeCapture {
  let content = '';
  let reasoningContent = '';
  let sawReasoningContent = false;
  let reasoningDetails = createOrderedReasoningDetails();
  const toolCalls = new Map<number, { id?: string; type?: string; name?: string; arguments: string }>();
  let invalid = false;
  const reset = () => {
    content = '';
    reasoningContent = '';
    sawReasoningContent = false;
    reasoningDetails = createOrderedReasoningDetails();
    toolCalls.clear();
    invalid = false;
  };
  return (_eventType, chunk) => {
    const choice = Array.isArray(chunk.choices) && isRecord(chunk.choices[0]) ? chunk.choices[0] : null;
    if (!choice) return [];
    const fragment = isRecord(choice.delta) ? choice.delta : isRecord(choice.message) ? choice.message : null;
    if (fragment) {
      if (typeof fragment.content === 'string') content += fragment.content;
      if (typeof fragment.reasoning_content === 'string') {
        reasoningContent += fragment.reasoning_content;
        sawReasoningContent = true;
      }
      if (Object.hasOwn(fragment, 'reasoning_details')
        && (!Array.isArray(fragment.reasoning_details)
          || !mergeReasoningDetails(reasoningDetails, fragment.reasoning_details))) invalid = true;
      if (Object.hasOwn(fragment, 'tool_calls')
        && (!Array.isArray(fragment.tool_calls)
          || !mergeStrictAssistantToolCalls(toolCalls, fragment.tool_calls))) invalid = true;
    }
    if (choice.finish_reason == null) return [];
    if (invalid) {
      reset();
      return [];
    }
    const assistant: Record<string, unknown> = { role: 'assistant', content };
    if (responseParserKind === 'openrouter_reasoning_v1') {
      const completeDetails = finalizedOrderedReasoningDetails(reasoningDetails);
      if (!completeDetails) {
        reset();
        return [];
      }
      assistant.reasoning_details = completeDetails;
    } else if ((responseParserKind === 'moonshot_reasoning_v1' || responseParserKind === 'deepseek_reasoning_v1') && sawReasoningContent) {
      assistant.reasoning_content = reasoningContent;
    } else {
      reset();
      return [];
    }
    if (toolCalls.size > 0) {
      const completeCalls = finalizedAssistantToolCalls(toolCalls);
      if (!completeCalls) {
        reset();
        return [];
      }
      assistant.tool_calls = completeCalls;
    }
    reset();
    return continuationEvents({ kind: 'replay_reasoning', step: 1, state: { assistantMessages: [assistant] } });
  };
}

function createMistralReasoningCapture(): RecipeCapture {
  let content: string | Array<Record<string, unknown>> | undefined;
  let invalidContent = false;
  const toolCalls = new Map<number, { id?: string; type?: string; name?: string; arguments: string }>();
  const reset = () => {
    content = undefined;
    invalidContent = false;
    toolCalls.clear();
  };
  return (_eventType, chunk) => {
    const choice = Array.isArray(chunk.choices) && isRecord(chunk.choices[0]) ? chunk.choices[0] : null;
    if (!choice) return [];
    const message = isRecord(choice.message) ? choice.message : null;
    const fragment = isRecord(choice.delta) ? choice.delta : message;
    if (fragment && Object.hasOwn(fragment, 'content')) {
      const next = fragment.content;
      if (message) {
        if (typeof next === 'string' || isExactMistralContentBlocks(next)) content = cloneJson(next);
        else invalidContent = true;
      } else if (!mergeMistralContentDelta(next, (value) => { content = value; }, content)) {
        invalidContent = true;
      }
    }
    if (fragment && Array.isArray(fragment.tool_calls)) mergeAssistantToolCalls(toolCalls, fragment.tool_calls);
    if (!message && choice.finish_reason == null) return [];
    if (invalidContent || content === undefined) {
      reset();
      return [];
    }
    const assistant: Record<string, unknown> = { role: 'assistant', content };
    if (toolCalls.size > 0) {
      const completeCalls = finalizedAssistantToolCalls(toolCalls);
      if (!completeCalls) {
        reset();
        return [];
      }
      assistant.tool_calls = completeCalls;
    }
    reset();
    return continuationEvents({ kind: 'replay_reasoning', step: 1, state: { assistantMessages: [assistant] } });
  };
}

function mergeMistralContentDelta(
  raw: unknown,
  update: (value: string | Array<Record<string, unknown>>) => void,
  current: string | Array<Record<string, unknown>> | undefined,
): boolean {
  if (typeof raw === 'string') {
    if (Array.isArray(current)) {
      if (raw.length > 0) appendMistralBlock(current, { type: 'text', text: raw });
      update(current);
    } else update(`${current ?? ''}${raw}`);
    return true;
  }
  if (!isExactMistralContentBlocks(raw)) return false;
  const blocks = Array.isArray(current)
    ? current
    : (typeof current === 'string' && current.length > 0 ? [{ type: 'text', text: current }] : []);
  raw.forEach((block) => appendMistralBlock(blocks, cloneJson(block)));
  update(blocks);
  return true;
}

function appendMistralBlock(target: Array<Record<string, unknown>>, block: Record<string, unknown>): void {
  const previous = target.at(-1);
  if (block.type === 'thinking' && previous?.type === 'thinking') {
    const previousThinking = previous.thinking as unknown[];
    previousThinking.push(...cloneJson(block.thinking as unknown[]));
    if (typeof block.closed === 'boolean') previous.closed = block.closed;
    return;
  }
  if (block.type === 'text' && previous?.type === 'text') {
    previous.text = `${String(previous.text)}${String(block.text)}`;
    return;
  }
  target.push(block);
}

function isExactMistralContentBlocks(value: unknown): value is Array<Record<string, unknown>> {
  return Array.isArray(value) && value.length > 0 && value.every((block) => {
    if (!isRecord(block)) return false;
    if (block.type === 'text') {
      return typeof block.text === 'string'
        && Object.keys(block).every((key) => key === 'type' || key === 'text');
    }
    if (block.type !== 'thinking' || !Array.isArray(block.thinking)) return false;
    return block.thinking.every((piece) => isRecord(piece)
      && piece.type === 'text'
      && typeof piece.text === 'string'
      && Object.keys(piece).every((key) => key === 'type' || key === 'text'))
      && (block.closed === undefined || typeof block.closed === 'boolean')
      && Object.keys(block).every((key) => ['type', 'thinking', 'closed'].includes(key));
  });
}

function finalizedAssistantToolCalls(
  toolCalls: Map<number, { id?: string; type?: string; name?: string; arguments: string }>,
): Array<Record<string, unknown>> | null {
  const complete = [...toolCalls.entries()].sort(([a], [b]) => a - b).map(([, call]) => {
    if (!call.id || call.type !== 'function' || !call.name) return null;
    return { id: call.id, type: call.type, function: { name: call.name, arguments: call.arguments } };
  });
  return complete.some((call) => call == null) ? null : complete as Array<Record<string, unknown>>;
}

interface OrderedReasoningDetails {
  ordered: Array<Record<string, unknown>>;
  indexedPositions: Map<number, number>;
}

function createOrderedReasoningDetails(): OrderedReasoningDetails {
  return { ordered: [], indexedPositions: new Map<number, number>() };
}

function mergeReasoningDetails(target: OrderedReasoningDetails, raw: unknown[]): boolean {
  if (raw.length === 0) return false;
  for (const entry of raw) {
    if (!isRecord(entry) || Object.keys(entry).length === 0) return false;
    if (!Object.hasOwn(entry, 'index')) {
      // OpenRouter no-index details are independent opaque records. Using the array offset as a
      // synthetic global identity makes every chunk's first entry collide at zero.
      target.ordered.push(cloneJson(entry));
      continue;
    }
    if (!Number.isInteger(entry.index) || (entry.index as number) < 0) return false;
    const index = entry.index as number;
    const existingPosition = target.indexedPositions.get(index);
    if (existingPosition == null) {
      target.indexedPositions.set(index, target.ordered.length);
      target.ordered.push(cloneJson(entry));
      continue;
    }
    const current = target.ordered[existingPosition];
    for (const [key, value] of Object.entries(entry)) {
      if (['text', 'summary', 'data'].includes(key)
        && typeof value === 'string' && typeof current[key] === 'string') {
        current[key] = `${current[key]}${value}`;
      } else if (!(key in current)) {
        current[key] = cloneJson(value);
      } else if (JSON.stringify(current[key]) !== JSON.stringify(value)) {
        return false;
      }
    }
  }
  return true;
}

function finalizedOrderedReasoningDetails(
  target: OrderedReasoningDetails,
): Array<Record<string, unknown>> | null {
  if (target.ordered.length === 0 || !target.ordered.every((detail) => {
    if (typeof detail.type !== 'string' || detail.type.length === 0) return false;
    if (detail.index !== undefined
      && (!Number.isInteger(detail.index) || (detail.index as number) < 0)) return false;
    return ['text', 'summary', 'data'].every((key) => detail[key] === undefined || typeof detail[key] === 'string');
  })) return null;
  return target.ordered;
}

function mergeStrictReasoningDetails(
  target: Map<number, Record<string, unknown>>,
  raw: unknown[],
): boolean {
  if (raw.length === 0) return false;
  for (let fallbackIndex = 0; fallbackIndex < raw.length; fallbackIndex += 1) {
    const entry = raw[fallbackIndex];
    if (!isRecord(entry) || Object.keys(entry).length === 0) return false;
    if (Object.hasOwn(entry, 'index')
      && (!Number.isInteger(entry.index) || (entry.index as number) < 0)) return false;
    const index = Object.hasOwn(entry, 'index') ? entry.index as number : fallbackIndex;
    const current = target.get(index) ?? {};
    for (const [key, value] of Object.entries(entry)) {
      if (['text', 'summary', 'data'].includes(key) && typeof value === 'string' && typeof current[key] === 'string') {
        current[key] = `${current[key]}${value}`;
      } else if (!(key in current)) {
        current[key] = cloneJson(value);
      } else if (JSON.stringify(current[key]) !== JSON.stringify(value)) {
        return false;
      }
    }
    target.set(index, current);
  }
  return true;
}

function mergeAssistantToolCalls(target: Map<number, { id?: string; type?: string; name?: string; arguments: string }>, raw: unknown[]): void {
  raw.forEach((entry, fallbackIndex) => {
    if (!isRecord(entry)) return;
    const index = Number.isInteger(entry.index) && (entry.index as number) >= 0 ? entry.index as number : fallbackIndex;
    const current = target.get(index) ?? { arguments: '' };
    if (typeof entry.id === 'string') current.id = entry.id;
    if (typeof entry.type === 'string') current.type = entry.type;
    if (isRecord(entry.function)) {
      if (typeof entry.function.name === 'string') current.name = entry.function.name;
      if (typeof entry.function.arguments === 'string') current.arguments += entry.function.arguments;
    }
    target.set(index, current);
  });
}

function mergeStrictAssistantToolCalls(
  target: Map<number, { id?: string; type?: string; name?: string; arguments: string }>,
  raw: unknown[],
): boolean {
  if (raw.length === 0) return false;
  for (let fallbackIndex = 0; fallbackIndex < raw.length; fallbackIndex += 1) {
    const entry = raw[fallbackIndex];
    if (!isRecord(entry)
      || !Object.keys(entry).every((key) => ['index', 'id', 'type', 'function'].includes(key))
      || (Object.hasOwn(entry, 'index') && (!Number.isInteger(entry.index) || (entry.index as number) < 0))) return false;
    const index = Object.hasOwn(entry, 'index') ? entry.index as number : fallbackIndex;
    const current = target.get(index) ?? { arguments: '' };
    if (Object.hasOwn(entry, 'id')) {
      if (typeof entry.id !== 'string' || (current.id !== undefined && current.id !== entry.id)) return false;
      current.id = entry.id;
    }
    if (Object.hasOwn(entry, 'type')) {
      if (entry.type !== 'function' || (current.type !== undefined && current.type !== entry.type)) return false;
      current.type = entry.type;
    }
    if (Object.hasOwn(entry, 'function')) {
      if (!isRecord(entry.function)
        || Object.keys(entry.function).length === 0
        || !Object.keys(entry.function).every((key) => key === 'name' || key === 'arguments')) return false;
      if (Object.hasOwn(entry.function, 'name')) {
        if (typeof entry.function.name !== 'string') return false;
        current.name = `${current.name ?? ''}${entry.function.name}`;
      }
      if (Object.hasOwn(entry.function, 'arguments')) {
        if (typeof entry.function.arguments !== 'string') return false;
        current.arguments += entry.function.arguments;
      }
    }
    if (!Object.hasOwn(entry, 'id') && !Object.hasOwn(entry, 'type') && !Object.hasOwn(entry, 'function')) return false;
    target.set(index, current);
  }
  return true;
}

function continuationEvents(intent: ContinuationIntent): StreamEvent[] {
  return validateContinuation(intent).accepted ? [{ type: 'continuation', continuation: intent }] : [];
}
function appendString(target: Record<string, unknown>, key: string, value: string): void {
  target[key] = `${typeof target[key] === 'string' ? target[key] : ''}${value}`;
}
function cloneJson<T>(value: T): T { return JSON.parse(JSON.stringify(value)) as T; }
function resetCapture(...maps: Array<Map<unknown, unknown>>): StreamEvent[] { maps.forEach((map) => map.clear()); return []; }

function parseToolCallDeltas(raw: unknown): StreamToolCallDelta[] {
  if (!Array.isArray(raw)) return [];

  const deltas: StreamToolCallDelta[] = [];
  raw.forEach((item, fallbackIndex) => {
    if (!isRecord(item)) return;
    const fn = isRecord(item.function) ? item.function : undefined;
    const name = typeof item.name === 'string' ? item.name : fn?.name;
    const argumentsFragment = typeof item.arguments === 'string'
      ? item.arguments
      : fn?.arguments;
    const hasID = typeof item.id === 'string';
    const hasType = typeof item.type === 'string';
    const hasName = typeof name === 'string';
    const hasArguments = typeof argumentsFragment === 'string';
    if (!hasID && !hasType && !hasName && !hasArguments) return;

    const index = typeof item.index === 'number'
      && Number.isInteger(item.index)
      && item.index >= 0
      ? item.index
      : fallbackIndex;
    deltas.push({
      index,
      ...(hasID ? { id: item.id as string } : {}),
      ...(hasType ? { type: item.type as string } : {}),
      ...(hasName ? { name: name as string } : {}),
      ...(hasArguments ? { arguments: argumentsFragment as string } : {}),
    });
  });
  return deltas;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function isProviderErrorSource(value: unknown): value is 'provider' | 'network' | 'oriveo' | 'desktop' | 'unknown' {
  return value === 'provider'
    || value === 'network'
    || value === 'oriveo'
    || value === 'desktop'
    || value === 'unknown';
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

function isStep(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0;
}

function isToolConfirmationReason(value: unknown): value is ToolConfirmationReason {
  return value === 'sensitive' || value === 'high_cost' || value === 'broad_read';
}

/**
 * Wrap raw upstream usage into a StreamUsage carrying a breakdown.
 * The prompt_tokens / completion_tokens / total_tokens fields are kept for telemetry and legacy
 * consumers; the breakdown lets deriveCostFields use the exact path and consume cache discount
 * fields such as cachedInputTokens.
 */
function buildUsageEvent(
  usage: Record<string, unknown>,
  pickUsage: (usage: Record<string, unknown>) => UsageBreakdown,
): StreamUsage {
  const breakdown = pickUsage(usage);
  return {
    prompt_tokens: typeof usage.prompt_tokens === 'number' ? usage.prompt_tokens : undefined,
    completion_tokens:
      typeof usage.completion_tokens === 'number' ? usage.completion_tokens : undefined,
    total_tokens: typeof usage.total_tokens === 'number' ? usage.total_tokens : undefined,
    breakdown,
  };
}

function resolveResponseStreamError(chunk: unknown): string {
  if (!chunk || typeof chunk !== 'object') return 'OpenAI Responses stream failed';

  const message = (chunk as {
    error?: { message?: string };
    message?: string;
  }).error?.message ?? (chunk as { message?: string }).message;

  return typeof message === 'string' && message.trim()
    ? message
    : 'OpenAI Responses stream failed';
}
