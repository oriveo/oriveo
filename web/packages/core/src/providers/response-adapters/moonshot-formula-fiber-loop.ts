/** Moonshot Formula/Fiber loop.
 *
 * Formula declarations are fetched from Kimi before the first chat leg.  A returned
 * function call is sent to Fiber with its `name` and *original argument string*;
 * Fiber output/encrypted_output is then replayed unchanged as a tool message.
 */
import type { UpstreamTransport } from '../../ports';
import type { ProviderRequest } from '../request-builders/types';
import type { UnsupportedParamDroppedReporter, UnsupportedParamScope } from '../unsupported-param';
import { toProviderError } from '../errors';

const SSE_HEADERS = { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' } as const;

export async function prepareMoonshotFormulaRequest(
  request: ProviderRequest,
  transport: UpstreamTransport,
  signal?: AbortSignal,
): Promise<ProviderRequest> {
  const formula = request.moonshotFormula;
  if (!formula) return request;
  const response = await transport.fetch(formulaURL(request.url, formula.toolsPath), {
    method: 'GET', headers: { Authorization: request.headers.Authorization ?? '', Accept: 'application/json' }, signal,
  });
  if (!response.ok) throw new FormulaError(`Moonshot Formula tools request failed (${response.status})`, 'provider');
  const raw: unknown = await response.json().catch(() => null);
  const tools = extractFormulaTools(raw);
  if (!tools) throw new FormulaError('Moonshot Formula tools response is invalid', 'provider');
  return { ...request, body: { ...request.body, tools: mergeFormulaTools(request.body.tools, tools) } };
}

export async function adaptMoonshotFormulaFiberResponse(
  upstream: Response,
  request: ProviderRequest,
  transport: UpstreamTransport,
  signal?: AbortSignal,
  // Retain the core call shape for desktop; no automatic field removal occurs.
  _onUnsupportedParamDropped?: UnsupportedParamDroppedReporter,
  _scope?: UnsupportedParamScope,
): Promise<Response> {
  const formula = request.moonshotFormula;
  if (!formula) throw new FormulaError('Moonshot Formula recipe is missing', 'provider');
  const maxLoops = Math.max(1, Math.min(request.moonshotMaxToolLoops ?? 1, 5));
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      const emit = (payload: string) => controller.enqueue(encoder.encode(`data: ${payload}\n\n`));
      const messages = Array.isArray(request.body.messages) ? [...request.body.messages as Array<Record<string, unknown>>] : [];
      const completedMessages: Array<Record<string, unknown>> = [];
      // Per-leg usage is intercepted (never forwarded); one closing usage event carries the
      // cross-leg totals plus raw per-leg usage (`legs`, null = leg reported none), same as moonshot-tool-loop.
      const totals: UsageTotals = { prompt: 0, completion: 0, cached: 0, seen: false };
      const legUsages: Array<Record<string, unknown> | null> = [];
      let response = upstream;
      try {
        for (let leg = 0; leg <= maxLoops; leg += 1) {
          const outcome = await pumpLeg(response, emit, totals);
          legUsages.push(outcome.usage);
          if (outcome.toolCalls.length === 0) break;
          // A tool call without a matching Fiber replay is an incomplete assistant turn.
          // Never emit [DONE] as if this were a successful answer when the bounded loop is spent.
          if (leg === maxLoops) throw new FormulaError('Moonshot Formula tool loop limit reached before completion', 'provider');
          const assistantToolCall = {
            role: 'assistant', content: outcome.text,
            ...(outcome.reasoning ? { reasoning_content: outcome.reasoning } : {}),
            tool_calls: outcome.toolCalls,
          };
          messages.push(assistantToolCall);
          completedMessages.push(assistantToolCall);
          for (const call of outcome.toolCalls) {
            const result = await runFiber(request, call, transport, signal);
            const toolResult = { role: 'tool', tool_call_id: call.id ?? '', name: call.function.name, content: result.output };
            messages.push(toolResult);
            completedMessages.push(toolResult);
            // Evidence that web search ran: the Fiber executed and returned a non-empty result.
            // The summary carries the tool name only, since the result may be encrypted and
            // search content does not belong in the execution fact.
            if (result.output.trim()) emit(JSON.stringify({ type: 'tool_result', tool: call.function.name, summary: call.function.name, step: leg + 1 }));
          }
          // Internal, recipe-required local replay state. It is emitted only after a whole Fiber
          // leg completed; the browser persists it locally and never auto-resumes it.
          emit(JSON.stringify({ type: 'continuation', continuation: {
            kind: 'tool_loop', variant: 'fiber', step: leg + 1, state: { completedMessages },
          } }));
          const next: ProviderRequest = { ...request, body: { ...request.body, messages } };
          // No reviewed locatorRules exist yet. Keep this replay leg intact and
          // surface the provider result instead of automatically deleting input.
          response = await transport.fetch(next.url, {
            method: 'POST', headers: next.headers, body: JSON.stringify(next.body), signal,
          });
          if (!response.ok) throw new FormulaError(toProviderError(response.status, await response.text().catch(() => ''), response.url).message, 'provider');
        }
        if (totals.seen) {
          emit(JSON.stringify({ type: 'usage', usage: {
            prompt_tokens: totals.prompt, completion_tokens: totals.completion,
            total_tokens: totals.prompt + totals.completion, cached_tokens: totals.cached, legs: legUsages,
          } }));
        }
      } catch (error) {
        if (!signal?.aborted) emit(JSON.stringify({ type: 'error', error: error instanceof Error ? error.message : 'Moonshot Formula loop failed', errorKind: 'upstream', source: error instanceof FormulaError ? error.source : 'network' }));
      }
      controller.enqueue(encoder.encode('data: [DONE]\n\n'));
      controller.close();
    },
  });
  return new Response(stream, { headers: SSE_HEADERS });
}

async function runFiber(request: ProviderRequest, call: ToolCall, transport: UpstreamTransport, signal?: AbortSignal): Promise<{ output: string; encrypted: boolean }> {
  const formula = request.moonshotFormula!;
  const response = await transport.fetch(formulaURL(request.url, formula.fibersPath), {
    method: 'POST', headers: { Authorization: request.headers.Authorization ?? '', 'Content-Type': 'application/json', Accept: 'application/json' },
    // Kimi's Formula contract: never parse/re-stringify `arguments`, even if it is invalid JSON.
    body: JSON.stringify({ name: call.function.name, arguments: call.function.arguments }), signal,
  });
  if (!response.ok) throw new FormulaError(`Moonshot Fiber request failed (${response.status})`, 'provider');
  const result: unknown = await response.json().catch(() => null);
  const output = fiberOutput(result);
  if (output == null) throw new FormulaError('Moonshot Fiber response has no replayable context output', 'provider');
  return output;
}

function formulaURL(chatURL: string, path: string): string {
  const chat = new URL(chatURL);
  const suffix = '/chat/completions';
  if (!chat.pathname.endsWith(suffix)) throw new FormulaError('Invalid Moonshot chat endpoint for Formula', 'provider');
  // Kimi's documented BASE_URL includes `/v1`. A compatible custom gateway may prepend its own
  // path (for example `/moonshot/v1`), so replace only the recipe's canonical `/v1` root with the
  // actual chat API root instead of dropping either prefix.
  const apiBase = chat.pathname.slice(0, -suffix.length);
  const canonicalPrefix = '/v1/formulas/';
  if (!apiBase.endsWith('/v1') || !path.startsWith(canonicalPrefix) || path.includes('?') || path.includes('#') || path.includes('..')) {
    throw new FormulaError('Invalid Moonshot Formula recipe path', 'provider');
  }
  return `${chat.origin}${apiBase}${path.slice('/v1'.length)}`;
}

function extractFormulaTools(value: unknown): Array<Record<string, unknown>> | null {
  const tools = isRecord(value) ? value.tools : value;
  if (!Array.isArray(tools) || tools.length === 0) return null;
  const names = new Set<string>();
  for (const tool of tools) {
    if (!isRecord(tool) || tool.type !== 'function' || !isRecord(tool.function) || typeof tool.function.name !== 'string' || !tool.function.name || names.has(tool.function.name)) return null;
    names.add(tool.function.name);
  }
  // preserve the remote declaration losslessly; it is not locally re-authored or normalized.
  return tools as Array<Record<string, unknown>>;
}

/** Formula declarations augment builder-owned/library tools; no array overwrite is permitted.
 * A repeated function name has ambiguous ownership at the upstream, so fail before chat POST. */
function mergeFormulaTools(base: unknown, formulaTools: Array<Record<string, unknown>>): Array<Record<string, unknown>> {
  const existing = Array.isArray(base) ? base : [];
  if (!existing.every(isRecord)) throw new FormulaError('Moonshot Formula base tools are invalid', 'provider');
  const names = new Set<string>();
  for (const tool of existing) {
    const name = functionToolName(tool);
    if (name && names.has(name)) throw new FormulaError(`Moonshot Formula duplicate tool name: ${name}`, 'provider');
    if (name) names.add(name);
  }
  for (const tool of formulaTools) {
    const name = functionToolName(tool);
    if (!name || names.has(name)) throw new FormulaError(`Moonshot Formula duplicate tool name: ${name ?? 'unknown'}`, 'provider');
    names.add(name);
  }
  return [...existing, ...formulaTools];
}

function functionToolName(tool: Record<string, unknown>): string | null {
  const fn = tool.function;
  return isRecord(fn) && typeof fn.name === 'string' && fn.name ? fn.name : null;
}

function fiberOutput(value: unknown): { output: string; encrypted: boolean } | null {
  const context = isRecord(value) && value.status === 'succeeded' && isRecord(value.context) ? value.context : null;
  if (!context) return null;
  if (typeof context.output === 'string') return { output: context.output, encrypted: false };
  if (typeof context.encrypted_output === 'string') return { output: context.encrypted_output, encrypted: true };
  return null;
}

async function pumpLeg(response: Response, emit: (payload: string) => void, totals: UsageTotals): Promise<LegOutcome> {
  if (!response.body) throw new FormulaError('Moonshot response has no body', 'provider');
  const reader = response.body.getReader(); const decoder = new TextDecoder(); let buffer = ''; let text = ''; let reasoning = '';
  const calls = new Map<number, ToolCallBuilder>();
  let usage: Record<string, unknown> | null = null;
  const consume = (payload: string) => {
    let chunk: StreamChunk; try { chunk = JSON.parse(payload) as StreamChunk; } catch { return; }
    const delta = chunk.choices?.[0]?.delta;
    let outgoing: string | null = payload;
    // Top-level usage first; Kimi streams may carry it in choices[0].usage instead (recorded moonshot*.sse).
    const legUsage = isRecord(chunk.usage) ? chunk.usage : isRecord(chunk.choices?.[0]?.usage) ? chunk.choices[0].usage : null;
    if (legUsage) {
      // Keep this leg's last raw usage and add it to the totals; strip it from the forwarded
      // chunk so the client never prices a single leg (or the last leg) as the whole message.
      // A frame that still carries a delta or a finish_reason is forwarded without its usage.
      usage = legUsage; totals.seen = true;
      totals.prompt += numberOrZero(legUsage.prompt_tokens); totals.completion += numberOrZero(legUsage.completion_tokens); totals.cached += numberOrZero(legUsage.cached_tokens);
      const finishReason = chunk.choices?.[0]?.finish_reason;
      outgoing = (delta && (delta.content || delta.reasoning_content || delta.tool_calls?.length)) || finishReason != null ? JSON.stringify(withoutUsage(chunk)) : null;
    }
    if (typeof delta?.content === 'string') text += delta.content;
    if (typeof delta?.reasoning_content === 'string') reasoning += delta.reasoning_content;
    for (const piece of delta?.tool_calls ?? []) {
      const index = piece.index ?? 0; const current = calls.get(index) ?? { arguments: '' };
      if (piece.id) current.id = piece.id; if (piece.type) current.type = piece.type;
      if (piece.function?.name) current.name = piece.function.name;
      if (typeof piece.function?.arguments === 'string') current.arguments += piece.function.arguments;
      calls.set(index, current);
    }
    if (outgoing) emit(outgoing);
  };
  while (true) { const { done, value } = await reader.read(); if (done) break; buffer += decoder.decode(value, { stream: true }); const lines = buffer.split('\n'); buffer = lines.pop() ?? ''; for (const line of lines) { const part = line.trim(); if (!part.startsWith('data: ')) continue; const payload = part.slice(6); if (payload === '[DONE]') return { text, reasoning, toolCalls: finalize(calls), usage }; consume(payload); } }
  return { text, reasoning, toolCalls: finalize(calls), usage };
}

/** Strips usage from the top level and from choices[0]; every other field (finish_reason included) is kept. */
function withoutUsage(chunk: StreamChunk): Record<string, unknown> {
  const { usage: _usage, ...rest } = chunk as Record<string, unknown>;
  if (!Array.isArray(chunk.choices) || chunk.choices.length === 0) return rest;
  const [first, ...others] = chunk.choices;
  const { usage: _choiceUsage, ...firstRest } = (first ?? {}) as Record<string, unknown>;
  return { ...rest, choices: [firstRest, ...others] };
}

function numberOrZero(value: unknown): number { return typeof value === 'number' && Number.isFinite(value) ? value : 0; }

function finalize(builders: Map<number, ToolCallBuilder>): ToolCall[] { return [...builders.entries()].sort(([a], [b]) => a - b).flatMap(([, value]) => value.name ? [{ id: value.id, type: value.type, function: { name: value.name, arguments: value.arguments } }] : []); }
function isRecord(value: unknown): value is Record<string, any> { return typeof value === 'object' && value != null && !Array.isArray(value); }
class FormulaError extends Error { constructor(message: string, readonly source: 'provider' | 'network') { super(message); this.name = 'FormulaError'; } }
interface ToolCall { id?: string; type?: string; function: { name: string; arguments: string } }
interface ToolCallBuilder { id?: string; type?: string; name?: string; arguments: string }
interface UsageTotals { prompt: number; completion: number; cached: number; seen: boolean }
interface LegOutcome { text: string; reasoning: string; toolCalls: ToolCall[]; /** This leg's last raw usage; null = none reported. */ usage: Record<string, unknown> | null }
interface StreamChunk { usage?: unknown; choices?: Array<{ finish_reason?: string | null; usage?: unknown; delta?: { content?: string; reasoning_content?: string; tool_calls?: Array<{ index?: number; id?: string; type?: string; function?: { name?: string; arguments?: string } }> } }> }
