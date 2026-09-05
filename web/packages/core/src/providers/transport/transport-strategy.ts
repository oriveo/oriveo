/**
 * The TransportStrategy interface.
 *
 * One Strategy implementation per protocol kind (12 in total).
 * A Strategy is responsible for:
 *   - buildRequestBody: assembling messages + options + profile.mergeParams into the request body
 *     upstream expects
 *   - parseStreamChunk: turning an SSE chunk into a list of StreamEvents, including citation
 *     normalisation
 *   - parseError: turning an upstream error body into an error object the client can use
 *
 * Upstream field-path deviations (Zhipu's link field, Anthropic's web_search_tool_result block type)
 * are tuned per known kind through `StreamShape` instead of adding a separate Strategy.
 */

import type { Citation } from '@oriveo/shared/pure-types';
import type { ContentPart, StreamEvent, StreamOptions } from '../types';
import type { StreamShape } from '@oriveo/core/metadata/types';
import type { TransportKind } from './transport-kind';

/** Context that persists across chunks while parsing an SSE stream. */
export interface StreamContext {
  /** Accumulated citations, merged into the message by the adapter when the stream ends. Deduplicated in arrival order. */
  citations: Citation[];
  /** Accumulated input tokens, for upstreams such as Anthropic that spread them across several events. */
  inputTokens: number;
  /** Strategy-specific state, e.g. the set of already emitted image ids used for deduplication. */
  state: Record<string, unknown>;
  /**
   * providerKind, injected by the adapter when it creates the ctx, so a strategy can pick the right
   * parseUsage implementation per provider inside parseStreamChunk: one openai_chat strategy is
   * shared by Moonshot / Qwen / Zhipu, but their usage fields all differ.
   */
  providerKind?: string;
}

export function createStreamContext(providerKind?: string): StreamContext {
  return { citations: [], inputTokens: 0, state: {}, providerKind };
}

/** Request input messages, matching the existing adapter signature. */
export interface BuildRequestInput {
  providerKind?: string;
  modelID: string;
  messages: {
    role: 'user' | 'assistant' | 'system';
    content: string | ContentPart[];
  }[];
  options?: StreamOptions;
  /** mergeParams from the webSearch profile, deep-merged into the request body. */
  mergeParams?: Record<string, unknown>;
}

export interface TransportStrategy {
  readonly kind: TransportKind;
  /** Builds the request body sent upstream, as a plain object before JSON serialization. */
  buildRequestBody(input: BuildRequestInput): Record<string, unknown>;
  /** Parses a single SSE chunk (eventType + data string). */
  parseStreamChunk(
    eventType: string | null,
    data: string,
    ctx: StreamContext,
    shape: StreamShape | null,
  ): StreamEvent | StreamEvent[] | null;
  /** Parses an HTTP error body into a human-readable message; adapters can call it from a catch block. */
  parseError(status: number, body: unknown): { message: string; detail?: string };
}
