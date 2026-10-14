import { isRelayGenerationSuccessResponse } from './relay-generation-response';
import type { RelayEndpointTransport } from './relay-endpoints';
import { sendRelayStream, type RelayMessages } from './relay-orchestrator';
import type { UpstreamTransport } from '../ports';
import type { ProxyToolDefinition } from './request-builders/runtime';

/**
 * The "Test capability" a Relay user taps: the pure-computation part - synthetic messages, function tools, time limits and response verdicts.
 * Fixture source of truth: `shared/test-fixtures/relay/capability-test.v1.json`.
 * The request itself is produced by the same constructors as ordinary chat; no request body is built separately here.
 */

export type RelayCapabilityTestKind = 'text' | 'image' | 'tool';
export type RelayCapabilityTestShortTransport = 'chat' | 'responses' | 'messages' | 'gemini';
/** notObserved: a 2xx was accepted, but no image-recognition / tool evidence is found in production parsing; like undetermined, it is not written and the old value is kept. */
export type RelayCapabilityTestVerdict = RelayCapabilityTestResponseVerdict | 'notObserved';
/** The verdict obtainable from a single HTTP response alone (excluding the evidence step). */
export type RelayCapabilityTestResponseVerdict = 'accepted' | 'rejected' | 'undetermined';
export type RelayCapabilityTestReason =
  | 'ok'
  | 'upstream_rejected'
  | 'not_found'
  | 'unauthorized'
  | 'forbidden'
  | 'rate_limited'
  | 'html'
  | 'server'
  | 'http'
  | 'network'
  | 'timeout'
  | 'not_observed';

/** Total time limit per item: from sending to reading the last byte. Not an idle timeout. */
export const RELAY_CAPABILITY_TEST_DEADLINE_MS = 30_000;
/** The output cap goes through the constructor's own max-tokens channel (`relayMaxOutputTokens`). */
export const RELAY_CAPABILITY_TEST_MAX_OUTPUT_TOKENS = 16;

const TEXT_PROMPT = 'Hi';
const IMAGE_PROMPT = 'What color is this image? Answer in one word.';
const IMAGE_MIME_TYPE = 'image/png';
const IMAGE_PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR42mP4z8CAFTEMLQkAKP8/wc53yE8AAAAASUVORK5CYII=';
const TOOL_PROMPT = 'What time is it? Use the tool.';
/** The built-in PNG is pure red: image-recognition evidence = visible text contains the whole word red (case-insensitive). */
export const RELAY_CAPABILITY_TEST_IMAGE_EXPECTED_ANSWER = 'red';
const TOOL_NAME = 'get_current_time';

/** Only these four protocols can be tested; others (llama.cpp native) return undefined. */
export function relayCapabilityTestShortTransport(
  transport: RelayEndpointTransport,
): RelayCapabilityTestShortTransport | undefined {
  switch (transport) {
    case 'openai_chat_completions':
      return 'chat';
    case 'openai_responses':
      return 'responses';
    case 'anthropic_messages':
      return 'messages';
    case 'gemini_generate_content':
      return 'gemini';
    default:
      return undefined;
  }
}

/** The synthetic user message of one test; the image is a PNG data URL that each protocol's constructor converts as is into its own image block. */
export function relayCapabilityTestMessages(kind: RelayCapabilityTestKind): RelayMessages {
  switch (kind) {
    case 'image':
      return [{ role: 'user', content: [
        { type: 'text', text: IMAGE_PROMPT },
        { type: 'image_url', image_url: { url: `data:${IMAGE_MIME_TYPE};base64,${IMAGE_PNG_BASE64}` } },
      ] }];
    case 'tool':
      return [{ role: 'user', content: TOOL_PROMPT }];
    case 'text':
    default:
      return [{ role: 'user', content: TEXT_PROMPT }];
  }
}

/** The only function tool an item carries (standard shape; the constructor converts it to the wire shape per protocol). */
export function relayCapabilityTestFunctionTool(): ProxyToolDefinition {
  return {
    type: 'function',
    function: {
      name: TOOL_NAME,
      description: 'Returns the current time. Has no side effects.',
      parameters: {
        type: 'object',
        properties: {
          timezone: { type: 'string', description: 'IANA time zone name, for example UTC.' },
        },
      },
    },
  };
}

export interface RelayCapabilityTestOutcome {
  verdict: RelayCapabilityTestVerdict;
  reason: RelayCapabilityTestReason;
}

/** Result classified by response only: never notObserved. */
export interface RelayCapabilityTestResponseOutcome extends RelayCapabilityTestOutcome {
  verdict: RelayCapabilityTestResponseVerdict;
  reason: Exclude<RelayCapabilityTestReason, 'not_observed'>;
}

const CONTENT_KEYS = ['choices', 'candidates', 'output', 'content'];
const SSE_OUTPUT_KEYS = ['choices', 'candidates', 'delta', 'output', 'content', 'content_block'];

/**
 * T1: one HTTP response (read in full) -> verdict + reason. When there is no HTTP response (network error / timeout) the caller records it.
 * Status codes that clearly mean "this input / this parameter is not accepted" are judged rejected, other non-2xx are undetermined; a 2xx web page is undetermined;
 * a 2xx stream follows the SSE rules, and other 2xx are judged rejected on "only a non-empty error and no generated content".
 */
export function classifyRelayCapabilityTestOutcome(input: {
  status: number;
  contentType?: string | null;
  body: string;
}): RelayCapabilityTestResponseOutcome {
  const { status } = input;
  if (status === 404) return { verdict: 'rejected', reason: 'not_found' };
  if (status === 400 || status === 415 || status === 422) return { verdict: 'rejected', reason: 'upstream_rejected' };
  if (status === 401) return { verdict: 'undetermined', reason: 'unauthorized' };
  if (status === 403) return { verdict: 'undetermined', reason: 'forbidden' };
  if (status === 429) return { verdict: 'undetermined', reason: 'rate_limited' };
  if (status >= 500 && status < 600) return { verdict: 'undetermined', reason: 'server' };
  if (status < 200 || status >= 300) return { verdict: 'undetermined', reason: 'http' };
  if (!isRelayGenerationSuccessResponse(input.body, input.contentType)) return { verdict: 'undetermined', reason: 'html' };
  const rejected = (input.contentType ?? '').toLowerCase().includes('text/event-stream')
    ? isSSEErrorWithoutOutput(input.body)
    : isErrorBodyWithoutContent(input.body);
  return rejected ? { verdict: 'rejected', reason: 'upstream_rejected' } : { verdict: 'accepted', reason: 'ok' };
}

/** Verdict only (used by the chat rejection loop and native-file fallback). */
export function classifyRelayCapabilityTestResponse(input: {
  status: number;
  contentType?: string | null;
  body: string;
}): RelayCapabilityTestResponseVerdict {
  return classifyRelayCapabilityTestOutcome(input).verdict;
}

function isPresent(record: Record<string, unknown>, key: string): boolean {
  return record[key] !== undefined && record[key] !== null;
}

function parseObject(text: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = JSON.parse(text);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

/** A 2xx whose body has only a non-empty `error` and no generated content: a rejection wrapped in 200 by the relay. */
function isErrorBodyWithoutContent(body: string): boolean {
  const record = parseObject(body.replace(/^﻿/, ''));
  if (!record || !isPresent(record, 'error')) return false;
  return !CONTENT_KEYS.some((key) => isPresent(record, key));
}

/** SSE: an error event and no output event -> rejected; non-JSON data lines and comment lines are ignored. */
function isSSEErrorWithoutOutput(body: string): boolean {
  let sawError = false;
  for (const line of body.replace(/^﻿/, '').split(/\r?\n/)) {
    if (!line.startsWith('data:')) continue;
    const event = parseObject(line.slice(5).trim());
    if (!event) continue;
    const type = typeof event.type === 'string' ? event.type : '';
    if (SSE_OUTPUT_KEYS.some((key) => isPresent(event, key)) || type.startsWith('response.output')) return false;
    if (isPresent(event, 'error') || type === 'error' || type === 'response.failed') sawError = true;
  }
  return sawError;
}

/** Whole word, case-insensitive: not preceded or followed by a letter / digit / underscore. */
function containsWholeWord(text: string, word: string): boolean {
  const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`(?<![\\p{L}\\p{N}_])${escaped}(?![\\p{L}\\p{N}_])`, 'iu').test(text);
}

/**
 * Evidence step: feed the whole 2xx response body to that protocol's production streaming parser (relay-orchestrator),
 * image recognition takes the visible text shown in chat (delta, excluding thinking), tools take the function names in the tool call events produced by the same parse.
 */
export async function relayCapabilityTestEvidence(
  kind: Exclude<RelayCapabilityTestKind, 'text'>,
  transport: RelayEndpointTransport,
  response: { status: number; contentType?: string | null; body: string },
): Promise<boolean> {
  const upstream: UpstreamTransport = {
    fetch: async () => new Response(response.body, {
      status: response.status,
      headers: { 'Content-Type': response.contentType ?? 'text/event-stream' },
    }),
  };
  const handle = sendRelayStream(
    '',
    'relay-capability-test',
    relayCapabilityTestMessages(kind),
    'https://relay-capability-test.invalid/v1',
    {
      relayTransport: transport,
      relayAuthMode: 'bearer',
      relayStream: true,
      relayMaxOutputTokens: RELAY_CAPABILITY_TEST_MAX_OUTPUT_TOKENS,
      ...(kind === 'tool' ? { relayFunctionTool: relayCapabilityTestFunctionTool() } : {}),
    },
    {
      transport: upstream,
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    },
  );
  let visibleText = '';
  let calledTool = false;
  const reader = handle.stream.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value.type === 'delta') visibleText += value.content;
      else if (value.type === 'tool_calls' && value.toolCalls.some((call) => call.name === TOOL_NAME)) calledTool = true;
    }
  } catch {
    // Error mid-parse: only the evidence already read counts.
  }
  return kind === 'image'
    ? containsWholeWord(visibleText, RELAY_CAPABILITY_TEST_IMAGE_EXPECTED_ANSWER)
    : calledTool;
}

/** One response -> verdict: classify by status / body first; for image-recognition / tool items, look for evidence after accepted, no evidence = notObserved. Text items need no evidence. */
export async function judgeRelayCapabilityTestResponse(
  kind: RelayCapabilityTestKind,
  transport: RelayEndpointTransport,
  response: { status: number; contentType?: string | null; body: string },
): Promise<RelayCapabilityTestOutcome> {
  const outcome = classifyRelayCapabilityTestOutcome(response);
  if (kind === 'text' || outcome.verdict !== 'accepted') return outcome;
  return await relayCapabilityTestEvidence(kind, transport, response)
    ? outcome
    : { verdict: 'notObserved', reason: 'not_observed' };
}
