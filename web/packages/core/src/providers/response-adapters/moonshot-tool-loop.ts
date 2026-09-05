// Moonshot built-in tool loop adapter, forwarding one streamed leg at a time.
// Upstream SSE chunks pass through unchanged in OpenAI format (the client's parseProxyChunk
// reads reasoning_content / content / model). If a leg ends with accumulated tool_calls, the
// $web_search arguments are fed back locally and the next streamed leg starts, up to
// maxLoops rounds. usage is intercepted per leg and summed across legs, since each leg is
// billed separately, and one total is emitted at the end.
import type { ProviderRequest } from "../request-builders/types";
import type { UpstreamTransport } from "../../ports";
import type { UnsupportedParamDroppedReporter, UnsupportedParamScope } from "../unsupported-param";
import { toProviderError } from "../errors";

const SSE_HEADERS = {
  "Content-Type": "text/event-stream",
  "Cache-Control": "no-cache",
  Connection: "keep-alive",
} as const;

export async function adaptMoonshotToolLoopResponse(
  upstream: Response,
  req: ProviderRequest,
  transport: UpstreamTransport,
  signal?: AbortSignal,
  // Kept for desktop call compatibility. P5's Web route deliberately passes
  // neither value and this adapter never invokes the legacy self-healer.
  _onUnsupportedParamDropped?: UnsupportedParamDroppedReporter,
  _scope?: UnsupportedParamScope,
): Promise<Response> {
  // Runtime recipe permits 1…5. The old hard cap of four silently ignored an official value.
  const maxLoops = Math.max(1, Math.min(req.moonshotMaxToolLoops ?? 4, 5));
  const encoder = new TextEncoder();

  const stream = new ReadableStream<Uint8Array>({
    async start(ctrl) {
      const emit = (payload: string) => {
        ctrl.enqueue(encoder.encode(`data: ${payload}\n\n`));
      };
      const messages = Array.isArray(req.body.messages)
        ? [...(req.body.messages as Array<Record<string, unknown>>)]
        : [];
      const totals = { prompt: 0, completion: 0, cached: 0, seen: false };
      const completedMessages: Array<Record<string, unknown>> = [];
      let anyReasoning = false;
      let response = upstream;

      try {
        for (let leg = 0; leg <= maxLoops; leg += 1) {
          const outcome = await pumpMoonshotLeg(response, emit, totals, anyReasoning);
          anyReasoning = anyReasoning || outcome.reasoning.length > 0;
          if (outcome.toolCalls.length === 0) break;
          if (leg === maxLoops) {
            throw new MoonshotToolLoopError("Moonshot builtin tool loop limit reached before completion", "provider");
          }

          for (const toolCall of outcome.toolCalls) {
            if (!toolCall.id || toolCall.function?.name !== "$web_search" || typeof toolCall.function.arguments !== "string") {
              throw new MoonshotToolLoopError("Moonshot builtin returned an invalid tool call", "provider");
            }
          }

          // Feed back: echo the assistant tool-call message plus the tool result, with
          // arguments returned verbatim.
          // Kimi contract: when thinking is in effect (enabled by default on k2.5/k2.6), an
          // assistant tool-call message without reasoning_content is rejected with 400. An
          // empty string passes, since the model may search without thinking first.
          const assistantToolCall = {
            role: "assistant",
            content: outcome.text,
            reasoning_content: outcome.reasoning,
            tool_calls: outcome.toolCalls,
          };
          messages.push(assistantToolCall);
          completedMessages.push(assistantToolCall);
          for (const toolCall of outcome.toolCalls) {
            const toolResult = {
              role: "tool",
              tool_call_id: toolCall.id!,
              name: toolCall.function!.name!,
              content: runMoonshotBuiltinTool(toolCall),
            };
            messages.push(toolResult);
            completedMessages.push(toolResult);
          }
          emit(JSON.stringify({ type: "continuation", continuation: {
            kind: "tool_loop", variant: "default", step: leg + 1,
            state: { completedMessages },
          } }));

          const nextRequest: ProviderRequest = {
            ...req,
            body: { ...req.body, messages },
          };
          // Current P5 metadata contains no reviewed locator rule. A generic
          // failure in this second leg must surface unchanged, never strip a
          // request field and retry behind the user's back.
          response = await transport.fetch(nextRequest.url, {
            method: "POST",
            headers: nextRequest.headers,
            body: JSON.stringify(nextRequest.body),
            signal,
          });
          if (!response.ok) {
            const detail = await response.text().catch(() => "");
            throw new MoonshotToolLoopError(
              toProviderError(response.status, detail, response.url).message,
              "provider",
            );
          }
        }

        if (totals.seen) {
          emit(JSON.stringify({
            type: "usage",
            usage: {
              prompt_tokens: totals.prompt,
              completion_tokens: totals.completion,
              total_tokens: totals.prompt + totals.completion,
              cached_tokens: totals.cached,
            },
          }));
        }
      } catch (error) {
        // Close quietly on abort: an AbortError is not an upstream failure, so no error
        // event is emitted and downstream decides 'cancelled' from abortSignal.aborted.
        // Otherwise a cross-process cancel of a multi-leg or fed-back leg would report an
        // interruption as a failure.
        if (!signal?.aborted) {
          emit(JSON.stringify({
            type: "error",
            error: error instanceof Error ? error.message : "Moonshot tool loop failed",
            errorKind: "upstream",
            source: error instanceof MoonshotToolLoopError ? error.source : "network",
          }));
        }
      }
      ctrl.enqueue(encoder.encode("data: [DONE]\n\n"));
      ctrl.close();
    },
  });

  return new Response(stream, { headers: SSE_HEADERS });
}

class MoonshotToolLoopError extends Error {
  constructor(
    message: string,
    readonly source: "provider" | "network",
  ) {
    super(message);
    this.name = "MoonshotToolLoopError";
  }
}

interface MoonshotLegOutcome {
  text: string;
  reasoning: string;
  toolCalls: MoonshotToolCall[];
}

/**
 * Read one streamed leg: non-usage chunks pass through unchanged (the client parser ignores
 * tool_calls chunks), usage chunks are intercepted and summed, tool_calls deltas are merged
 * by index, and the per-leg totals are returned for the feed-back step.
 */
async function pumpMoonshotLeg(
  response: Response,
  emit: (payload: string) => void,
  totals: { prompt: number; completion: number; cached: number; seen: boolean },
  hadReasoning: boolean,
): Promise<MoonshotLegOutcome> {
  if (!response.body) {
    throw new MoonshotToolLoopError("Moonshot response has no body", "provider");
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let text = "";
  let reasoning = "";
  const builders = new Map<number, MoonshotToolCallBuilder>();

  const handlePayload = (payload: string) => {
    let chunk: MoonshotStreamChunk;
    try {
      chunk = JSON.parse(payload) as MoonshotStreamChunk;
    } catch {
      return;
    }
    const delta = chunk.choices?.[0]?.delta;
    let outgoing: string | null = payload;
    if (chunk.usage && typeof chunk.usage === "object") {
      totals.seen = true;
      totals.prompt += numberOrZero(chunk.usage.prompt_tokens);
      totals.completion += numberOrZero(chunk.usage.completion_tokens);
      totals.cached += numberOrZero(chunk.usage.cached_tokens);
      // usage is intercepted and summed across legs: it is stripped before forwarding so the client does not count each leg twice, and a chunk with nothing left after stripping is not sent
      if (delta && (delta.content || delta.reasoning_content || delta.tool_calls?.length)) {
        const { usage: _usage, ...rest } = chunk as Record<string, unknown>;
        outgoing = JSON.stringify(rest);
      } else {
        outgoing = null;
      }
    }
    for (const toolDelta of delta?.tool_calls ?? []) {
      const index = toolDelta.index ?? 0;
      const builder = builders.get(index) ?? { arguments: "" };
      if (toolDelta.id) builder.id = toolDelta.id;
      if (toolDelta.type) builder.type = toolDelta.type;
      if (toolDelta.function?.name) builder.name = toolDelta.function.name;
      if (toolDelta.function?.arguments) builder.arguments += toolDelta.function.arguments;
      builders.set(index, builder);
    }

    const reasoningDelta = delta?.reasoning_content;
    if (typeof reasoningDelta === "string" && reasoningDelta) {
      // Insert the paragraph break between legs, so the streamed accumulation and the final text
      // match character for character.
      if (!reasoning && hadReasoning) {
        emit(JSON.stringify({ choices: [{ delta: { reasoning_content: "\n\n" } }] }));
      }
      reasoning += reasoningDelta;
    }
    const contentDelta = delta?.content;
    if (typeof contentDelta === "string" && contentDelta) {
      text += contentDelta;
    }
    if (outgoing) emit(outgoing);
  };

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("data: ")) continue;
      const payload = trimmed.slice(6);
      if (payload === "[DONE]") {
        return { text, reasoning, toolCalls: finalizeToolCalls(builders) };
      }
      handlePayload(payload);
    }
  }
  return { text, reasoning, toolCalls: finalizeToolCalls(builders) };
}

export function runMoonshotBuiltinTool(toolCall: MoonshotToolCall): string {
  const name = toolCall.function?.name;
  if (name !== "$web_search") {
    return JSON.stringify({ error: `Unsupported tool: ${name || "unknown"}` });
  }
  return toolCall.function?.arguments || "{}";
}

function finalizeToolCalls(builders: Map<number, MoonshotToolCallBuilder>): MoonshotToolCall[] {
  return [...builders.entries()]
    .sort(([a], [b]) => a - b)
    .map(([, builder]) => ({
      id: builder.id,
      type: builder.type,
      function: { name: builder.name, arguments: builder.arguments },
    }));
}

function numberOrZero(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

interface MoonshotStreamChunk {
  choices?: Array<{
    delta?: {
      content?: string;
      reasoning_content?: string;
      tool_calls?: MoonshotToolCallDelta[];
    };
  }>;
  usage?: {
    prompt_tokens?: unknown;
    completion_tokens?: unknown;
    cached_tokens?: unknown;
  };
}

/** A streamed tool_calls delta fragment: id/type/name appear only in the first fragment, while arguments are split across fragments */
interface MoonshotToolCallDelta {
  index?: number;
  id?: string;
  type?: string;
  function?: { name?: string; arguments?: string };
}

interface MoonshotToolCall {
  id?: string;
  type?: string;
  function?: { name?: string; arguments?: string };
}

interface MoonshotToolCallBuilder {
  id?: string;
  type?: string;
  name?: string;
  arguments: string;
}
