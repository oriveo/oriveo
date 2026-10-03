import type {
  ProxyMessage,
  ProxyToolCall,
  ProxyToolDefinition,
} from '../providers/request-builders/runtime';
import type { ContinuationIntent } from '../providers/request-preference/continuation';
import {
  finalizeToolCalls,
  mergeToolCallDeltas,
  type ToolCallAccumulator,
} from '../providers/tool-call-accumulator';
import type { StreamEvent, StreamUsage } from '../providers/types';
import {
  DEFAULT_MAX_CONSECUTIVE_TOOL_FAILURES,
  DEFAULT_MAX_SELF_CORRECTIONS,
  DEFAULT_TOOL_LOOP_STOPPED_ERROR_CODE,
  ToolCallRejection,
  ToolLoopError,
  defaultToolLoopPrompts,
  openAIChatToolAdapter,
  TOOL_LOOP_DEFAULT_MAX_STEPS,
  type ToolExecutionOutcome,
  type ToolLoopLegRequest,
  type ToolLoopLegRunner,
  type ToolLoopLimits,
  type ToolLoopProgressEvent,
  type ToolLoopPrompts,
  type ToolLoopResult,
  type ToolProtocolAdapter,
} from './tool-loop-contracts';
import { ToolRegistry } from './tool-registry';

export interface ToolCallLoopOptions {
  registry: ToolRegistry;
  /** Leg runner: send the request → parse the stream → emit events. The loop knows no concrete tool or protocol. */
  runLeg: ToolLoopLegRunner;
  signal: AbortSignal;
  limits: ToolLoopLimits;
  /** Protocol adapter; defaults to the openai_chat wire shape. */
  adapter?: ToolProtocolAdapter;
  prompts?: ToolLoopPrompts;
  /**
   * Error code fed back for skipped proposals when the loop wraps up early because of the step limit,
   * the token budget or an entry's `stopReason`. Defaults to `tool_loop_stopped`; the library uses
   * `research_stopped`.
   */
  stoppedErrorCode?: string;
  /** Proposals that missed the registry (never silent: the caller uses this for the "no executor" hint card and analytics). */
  onUnhandledToolCalls?: (calls: ProxyToolCall[]) => void | Promise<void>;
  /**
   * Prefix of the fallback the loop fills in when a call id is missing, encoded as
   * `<prefix>_<leg>_<index>`. Defaults to `tool_call`; the library uses `library_call`.
   */
  callIdFallbackPrefix?: string;
  /**
   * Whether each leg of the main loop sends the registry definitions to the model. With `disabled` every
   * leg has `tools=[]` and `tool_choice=none` (the no-tools fallback after a first-leg rejection, and
   * direct sends on connections that do not support tools); the synthesis leg is always none.
   */
  toolsMode?: 'enabled' | 'disabled';
  /**
   * How proposals that miss the registry are handled. `handoff` (default) passes them to
   * `onUnhandledToolCalls` and ends the run when a whole leg missed; `selfCorrect` treats them as "the
   * model misspelled the tool name", counts them as a `ToolCallRejection` self-correction and continues
   * with the next leg (the library's unknown_tool semantics).
   */
  unhandledToolCalls?: 'handoff' | 'selfCorrect';
  /** Text fed back for unknown_tool in `selfCorrect` mode; defaults to `Unsupported tool: <name>`. */
  unknownToolMessage?: (name: string) => string;
  /**
   * Hook for when the first leg answers directly without a single tool call that hit the registry:
   * returning a set of messages injects them and switches to the tool-less synthesis leg; returning null
   * keeps "the first leg's text is the answer".
   */
  onFirstLegWithoutToolCalls?: (
    legText: string,
  ) => Promise<readonly ProxyMessage[] | null>;
}

interface ConsumedLeg {
  text: string;
  toolCalls: ProxyToolCall[];
  usage?: StreamUsage;
  continuation?: ContinuationIntent;
}

/**
 * Generic tool loop: receive tool_calls → look up the registry → execute → feed back through the adapter
 * → next leg → maxSteps.
 *
 * Library retrieval and MCP tools share this single loop; every feature difference lives in the registry
 * entries (execution and failure disposition) and in how the caller consumes progress events. The loop
 * itself knows no concrete tool. Pure logic, testable under Node.
 */
export class ToolCallLoop {
  private readonly registry: ToolRegistry;
  private readonly runLeg: ToolLoopLegRunner;
  private readonly signal: AbortSignal;
  private readonly adapter: ToolProtocolAdapter;
  private readonly prompts: ToolLoopPrompts;
  private readonly stoppedErrorCode: string;
  private readonly onUnhandledToolCalls: (calls: ProxyToolCall[]) => void | Promise<void>;
  private readonly maxSteps: number;
  private readonly maxSelfCorrections: number;
  private readonly maxConsecutiveToolFailures: number;
  private readonly tokenBudget?: number;
  private readonly callIdFallbackPrefix: string;
  private readonly toolsMode: 'enabled' | 'disabled';
  private readonly unhandledToolCalls: 'handoff' | 'selfCorrect';
  private readonly unknownToolMessage: (name: string) => string;
  private readonly onFirstLegWithoutToolCalls?: (
    legText: string,
  ) => Promise<readonly ProxyMessage[] | null>;

  constructor(options: ToolCallLoopOptions) {
    this.registry = options.registry;
    this.runLeg = options.runLeg;
    this.signal = options.signal;
    this.adapter = options.adapter ?? openAIChatToolAdapter;
    this.prompts = options.prompts ?? defaultToolLoopPrompts;
    this.stoppedErrorCode = options.stoppedErrorCode ?? DEFAULT_TOOL_LOOP_STOPPED_ERROR_CODE;
    this.onUnhandledToolCalls = options.onUnhandledToolCalls ?? (() => {});
    this.maxSteps = normalizeMaxSteps(options.limits.maxSteps);
    this.maxSelfCorrections =
      options.limits.maxSelfCorrections ?? DEFAULT_MAX_SELF_CORRECTIONS;
    this.maxConsecutiveToolFailures =
      options.limits.maxConsecutiveToolFailures ?? DEFAULT_MAX_CONSECUTIVE_TOOL_FAILURES;
    this.tokenBudget = options.limits.tokenBudget;
    this.callIdFallbackPrefix = options.callIdFallbackPrefix ?? 'tool_call';
    this.toolsMode = options.toolsMode ?? 'enabled';
    this.unhandledToolCalls = options.unhandledToolCalls ?? 'handoff';
    this.unknownToolMessage =
      options.unknownToolMessage ?? ((name) => `Unsupported tool: ${name}`);
    this.onFirstLegWithoutToolCalls = options.onFirstLegWithoutToolCalls;
  }

  async run(
    initialMessages: readonly ProxyMessage[],
    onProgress: (event: ToolLoopProgressEvent) => void | Promise<void> = () => {},
  ): Promise<ToolLoopResult> {
    const tools = this.toolsMode === 'disabled' ? [] : this.registry.definitions;
    let history: ProxyMessage[] = [...initialMessages];
    const legTexts: string[] = [];
    let usage: StreamUsage | undefined;
    let selfCorrections = 0;
    let consecutiveToolFailures = 0;
    let executedToolSteps = 0;
    let receivedStructuredToolCalls = false;
    let forceSynthesis = false;
    let stepLimitReached = false;

    for (let legIndex = 0; legIndex < this.maxSteps; legIndex += 1) {
      throwIfAborted(this.signal);
      await onProgress({ type: 'legStarted', legIndex });
      const leg = await this.consumeLeg(
        {
          messages: history,
          tools,
          toolChoice: this.toolsMode === 'disabled' ? 'none' : 'auto',
        },
        legIndex,
        onProgress,
      );
      legTexts.push(leg.text);
      usage = mergeToolLoopUsage(usage, leg.usage);
      if (usage) await onProgress({ type: 'usage', usage });

      if (leg.toolCalls.length === 0) {
        // Zero tool calls on the first leg signals "the model answered without retrieving": the caller
        // may inject server-side evidence and re-answer through the synthesis leg. Returning null keeps
        // the original behaviour.
        if (legIndex === 0 && this.onFirstLegWithoutToolCalls) {
          const injected = await this.onFirstLegWithoutToolCalls(leg.text);
          if (injected) {
            history = [...injected];
            forceSynthesis = true;
            break;
          }
        }
        return {
          text: leg.text,
          legTexts,
          usage,
          endedWithoutToolCall: legIndex === 0,
          stepLimitReached: false,
          receivedStructuredToolCalls,
          executedToolSteps,
        };
      }
      receivedStructuredToolCalls = true;

      const handoff = this.unhandledToolCalls === 'handoff';
      const { accepted: registered, unhandled } = partitionToolCalls(
        this.registry,
        leg.toolCalls,
      );
      // selfCorrect: names missing from the registry are treated as misspelled tool names and handled in
      // the original order together with the proposals that hit.
      const accepted = handoff ? registered : [...leg.toolCalls];
      if (handoff) {
        if (unhandled.length > 0) await this.onUnhandledToolCalls(unhandled);
        if (accepted.length === 0) {
          // The whole leg consists of tools this connection cannot execute: we cannot give the model
          // what it wants, and further legs would only spin.
          return {
            text: leg.text,
            legTexts,
            usage,
            endedWithoutToolCall: legIndex === 0,
            stepLimitReached: false,
            receivedStructuredToolCalls: true,
            executedToolSteps,
          };
        }
      }
      await onProgress({ type: 'toolCallsAccepted', calls: accepted });

      const assistantMessage = this.adapter.encodeAssistantToolCalls({
        text: leg.text,
        toolCalls: leg.toolCalls,
        ...(leg.continuation ? { continuation: leg.continuation } : {}),
      });
      history.push(assistantMessage);

      // Tool results are fed back in the upstream's proposal order (misses in a mixed leg are not moved
      // to the front as a group); appended system sentences come after all results.
      const resultsByCallID = new Map<string, ProxyMessage>();
      const trailingSystemMessages: ProxyMessage[] = [];
      const feed = (message: ProxyMessage): void => {
        if (message.tool_call_id) resultsByCallID.set(message.tool_call_id, message);
      };
      const appendSystem = (content: string): void => {
        trailingSystemMessages.push({ role: 'system', content });
      };
      const commitLeg = (): void => {
        const ordered = leg.toolCalls.flatMap((call) => {
          const message = resultsByCallID.get(call.id);
          return message ? [message] : [];
        });
        history.push(...ordered, ...trailingSystemMessages);
      };

      // The protocol requires a tool message for every tool_call: the misses of a mixed leg get an
      // unknown_tool reply. In selfCorrect mode misses are fed back as rejections in order further down,
      // not up front here.
      if (handoff) {
        for (const call of unhandled) {
          feed(
            this.adapter.encodeToolResult({
              callID: call.id,
              toolName: call.function.name,
              content: errorContent('unknown_tool', `Unsupported tool: ${call.function.name}`),
            }),
          );
        }
      }

      if (this.tokenBudget != null && usageTotalTokens(usage) >= this.tokenBudget) {
        for (const call of accepted) {
          feed(
            this.adapter.encodeToolResult({
              callID: call.id,
              toolName: call.function.name,
              content: errorContent(this.stoppedErrorCode, this.prompts.stoppedByTokenBudget),
            }),
          );
        }
        appendSystem(this.prompts.tokenBudgetReached);
        forceSynthesis = true;
        commitLeg();
        break;
      }

      for (let callIndex = 0; callIndex < accepted.length; callIndex += 1) {
        // After the user pressed stop, none of the tools of this leg that have not started may run:
        // for read-only tools it would not matter, but a tool that writes data (an auto-run MCP tool)
        // still writing after "stop" is unacceptable.
        throwIfAborted(this.signal);
        const call = accepted[callIndex];
        const entry = this.registry.entry(call.function.name);
        if (!entry) {
          // selfCorrect mode: the model used a tool name the registry does not have; count it as a
          // self-correction like wrong arguments.
          const message = this.unknownToolMessage(call.function.name);
          selfCorrections += 1;
          feed(
            this.adapter.encodeToolResult({
              callID: call.id,
              toolName: call.function.name,
              content: errorContent('unknown_tool', message),
            }),
          );
          if (selfCorrections > this.maxSelfCorrections) {
            throw new ToolCallRejection('unknown_tool', message);
          }
          continue;
        }
        const stepNumber = executedToolSteps + 1;
        let stopThisLeg = false;
        try {
          const outcome: ToolExecutionOutcome = await entry.execute(call, {
            callID: call.id,
            stepNumber,
            legIndex,
            signal: this.signal,
          });
          executedToolSteps = stepNumber;
          consecutiveToolFailures = 0;
          feed(
            this.adapter.encodeToolResult({
              callID: call.id,
              toolName: call.function.name,
              content: outcome.content,
            }),
          );
          if (outcome.stopReason !== undefined) {
            appendSystem(outcome.stopReason);
            const stoppedMessage = outcome.stoppedMessage ?? outcome.stopReason;
            for (const skipped of accepted.slice(callIndex + 1)) {
              feed(
                this.adapter.encodeToolResult({
                  callID: skipped.id,
                  toolName: skipped.function.name,
                  content: errorContent(this.stoppedErrorCode, stoppedMessage),
                }),
              );
            }
            forceSynthesis = true;
            stopThisLeg = true;
          }
        } catch (error) {
          if (error instanceof ToolCallRejection) {
            selfCorrections += 1;
            feed(
              this.adapter.encodeToolResult({
                callID: call.id,
                toolName: call.function.name,
                content: errorContent(error.code, error.message),
              }),
            );
            if (selfCorrections > this.maxSelfCorrections) throw error;
            continue;
          }
          if (isAbortError(error)) throw error;
          const disposition = entry.failureDisposition(error);
          if (disposition.kind === 'fatal') throw error;
          // A non-abort error thrown by a tool while stopping (a cancellation wrapped by the entry) is a
          // consequence of the cancellation, not a real failure: wind down as cancelled, no feedback, no
          // counting.
          throwIfAborted(this.signal);
          // A single tool failure only loses that one call and does not blow up the run: the model
          // carries on with other evidence. Throwing the whole run would turn the entire message into an
          // error card - discarding all evidence already gathered because one document could not be read
          // is clearly worse.
          executedToolSteps = stepNumber;
          // neutral leaves the count alone: no increment (it is no evidence of a fault) and no reset (it
          // is no evidence of success).
          if (disposition.kind === 'degrade') consecutiveToolFailures += 1;
          feed(
            this.adapter.encodeToolResult({
              callID: call.id,
              toolName: call.function.name,
              content: errorContent(disposition.code, disposition.message),
            }),
          );
          if (
            disposition.kind === 'degrade' &&
            consecutiveToolFailures >= this.maxConsecutiveToolFailures
          ) {
            throw error;
          }
        }

        if (stopThisLeg) break;

        if (executedToolSteps >= this.maxSteps) {
          for (const skipped of accepted.slice(callIndex + 1)) {
            feed(
              this.adapter.encodeToolResult({
                callID: skipped.id,
                toolName: skipped.function.name,
                content: errorContent(this.stoppedErrorCode, this.prompts.stoppedByStepLimit),
              }),
            );
          }
          appendSystem(this.prompts.stepLimitReached);
          forceSynthesis = true;
          stepLimitReached = true;
          break;
        }
      }

      commitLeg();
      if (forceSynthesis) break;
    }

    if (!forceSynthesis) {
      // Legs exhausted: the same "limit reached" as the step limit.
      history.push({ role: 'system', content: this.prompts.stepLimitReached });
      stepLimitReached = true;
    }
    // The synthesis leg is a real upstream request too: if the user pressed stop while the last tool was
    // running, it must not be sent.
    throwIfAborted(this.signal);
    const finalIndex = Math.max(0, this.maxSteps);
    await onProgress({ type: 'legStarted', legIndex: finalIndex });
    const finalLeg = await this.consumeLeg(
      { messages: history, tools, toolChoice: 'none' },
      finalIndex,
      onProgress,
    );
    legTexts.push(finalLeg.text);
    usage = mergeToolLoopUsage(usage, finalLeg.usage);
    if (usage) await onProgress({ type: 'usage', usage });
    // With toolChoice = none there should be no more proposals; if one arrives anyway there is nowhere
    // to execute it, so hand it out instead of swallowing it.
    if (finalLeg.toolCalls.length > 0) await this.onUnhandledToolCalls(finalLeg.toolCalls);
    return {
      text: finalLeg.text,
      legTexts,
      usage,
      endedWithoutToolCall: false,
      stepLimitReached,
      receivedStructuredToolCalls,
      executedToolSteps,
    };
  }

  private async consumeLeg(
    request: ToolLoopLegRequest,
    legIndex: number,
    onProgress: (event: ToolLoopProgressEvent) => void | Promise<void>,
  ): Promise<ConsumedLeg> {
    const handle = this.runLeg(request);
    const onAbort = (): void => handle.abort();
    this.signal.addEventListener('abort', onAbort, { once: true });
    const reader = handle.stream.getReader();
    let text = '';
    let usage: StreamUsage | undefined;
    let continuation: ContinuationIntent | undefined;
    const accumulated: ToolCallAccumulator = new Map();
    let streamStarted = false;
    try {
      for (;;) {
        throwIfAborted(this.signal);
        const next = await reader.read();
        throwIfAborted(this.signal);
        if (next.done) break;
        const event: StreamEvent = next.value;
        if (event.type !== 'error') streamStarted = true;
        switch (event.type) {
          case 'delta':
            text += event.content;
            await onProgress({ type: 'textDelta', text: event.content });
            break;
          case 'reasoning':
            // Reasoning does not go into leg.text: it is not the model's answer to the user and must not
            // count as "the first leg already answered with zero tool calls".
            await onProgress({ type: 'reasoningDelta', text: event.content });
            break;
          case 'tool_calls':
            mergeToolCallDeltas(accumulated, event.toolCalls);
            break;
          case 'usage':
            usage = event.usage;
            break;
          case 'continuation':
            continuation = event.continuation;
            break;
          case 'error':
            throw new ToolLoopError(event.error, event.errorKind ?? 'upstream_error', {
              source: event.source,
              streamStarted,
              toolCallRejectionContext: handle.getToolCallRejectionContext?.(),
            });
          default:
            break;
        }
      }
    } finally {
      this.signal.removeEventListener('abort', onAbort);
      reader.releaseLock();
    }
    return {
      text,
      toolCalls: finalizeToolCalls(
        accumulated,
        `${this.callIdFallbackPrefix}_${legIndex + 1}`,
      ).map((call) => ({
        id: call.id,
        type: 'function' as const,
        function: { name: call.name, arguments: call.arguments },
      })),
      usage,
      ...(continuation ? { continuation } : {}),
    };
  }
}

function partitionToolCalls(
  registry: ToolRegistry,
  calls: readonly ProxyToolCall[],
): { accepted: ProxyToolCall[]; unhandled: ProxyToolCall[] } {
  const accepted: ProxyToolCall[] = [];
  const unhandled: ProxyToolCall[] = [];
  for (const call of calls) {
    if (registry.has(call.function.name)) accepted.push(call);
    else unhandled.push(call);
  }
  return { accepted, unhandled };
}

function normalizeMaxSteps(value: number): number {
  if (!Number.isFinite(value)) return TOOL_LOOP_DEFAULT_MAX_STEPS;
  return Math.max(0, Math.floor(value));
}

function errorContent(code: string, message: string): string {
  return JSON.stringify({ ok: false, error: { code, message } });
}

function usageTotalTokens(usage: StreamUsage | undefined): number {
  if (!usage) return 0;
  const componentTotal = (usage.prompt_tokens ?? 0) + (usage.completion_tokens ?? 0);
  if (typeof usage.total_tokens === 'number' && Number.isFinite(usage.total_tokens)) {
    return Math.max(usage.total_tokens, componentTotal);
  }
  return componentTotal;
}

function mergeToolLoopUsage(
  current: StreamUsage | undefined,
  next: StreamUsage | undefined,
): StreamUsage | undefined {
  if (!next) return current;
  if (!current) return next;
  const sumOptional = (left: number | undefined, right: number | undefined): number | undefined =>
    left == null && right == null ? undefined : (left ?? 0) + (right ?? 0);
  const leftBreakdown = current.breakdown;
  const rightBreakdown = next.breakdown;
  return {
    prompt_tokens: sumOptional(current.prompt_tokens, next.prompt_tokens),
    completion_tokens: sumOptional(current.completion_tokens, next.completion_tokens),
    total_tokens: sumOptional(current.total_tokens, next.total_tokens),
    breakdown:
      leftBreakdown || rightBreakdown
        ? {
            promptTokens:
              (leftBreakdown?.promptTokens ?? 0) + (rightBreakdown?.promptTokens ?? 0),
            cachedInputTokens:
              (leftBreakdown?.cachedInputTokens ?? 0) +
              (rightBreakdown?.cachedInputTokens ?? 0),
            cacheCreation5mTokens:
              (leftBreakdown?.cacheCreation5mTokens ?? 0) +
              (rightBreakdown?.cacheCreation5mTokens ?? 0),
            cacheCreation1hTokens:
              (leftBreakdown?.cacheCreation1hTokens ?? 0) +
              (rightBreakdown?.cacheCreation1hTokens ?? 0),
            completionTokens:
              (leftBreakdown?.completionTokens ?? 0) +
              (rightBreakdown?.completionTokens ?? 0),
            reasoningTokens:
              (leftBreakdown?.reasoningTokens ?? 0) + (rightBreakdown?.reasoningTokens ?? 0),
            upstreamCost: sumOptional(leftBreakdown?.upstreamCost, rightBreakdown?.upstreamCost),
            // The observed flag has to follow the legs: once the upstream of any leg explicitly reported
            // a cache breakdown, a 0 in the sum is the real information "no cache hit this time", not
            // "the upstream did not report".
            cacheReadObserved: Boolean(
              leftBreakdown?.cacheReadObserved || rightBreakdown?.cacheReadObserved,
            ),
            cacheWriteObserved: Boolean(
              leftBreakdown?.cacheWriteObserved || rightBreakdown?.cacheWriteObserved,
            ),
          }
        : undefined,
  };
}

function throwIfAborted(signal: AbortSignal): void {
  if (signal.aborted) throw new DOMException('Aborted', 'AbortError');
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError';
}
