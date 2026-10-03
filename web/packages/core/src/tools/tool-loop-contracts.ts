import type { ProviderErrorSource } from '../providers/errors';
import type { ContinuationIntent } from '../providers/request-preference/continuation';
import type {
  ProxyMessage,
  ProxyToolCall,
  ProxyToolDefinition,
} from '../providers/request-builders/runtime';
import type { StreamHandle, StreamUsage } from '../providers/types';

// Neutral contracts of the generic tool loop (same mechanics as the iOS Core/Tools/ToolLoopContracts.swift,
// without copying its API names).
//
// Library retrieval and MCP tools share this one loop; every feature difference lives in the registry
// entries (execution and failure disposition) and in how the caller consumes progress events. The loop
// itself knows no concrete tool. Pure logic, testable under Node.

/** Tool scope. */
export type ToolScope = 'library' | 'web' | 'mcp';

/**
 * A registry entry refuses a call (argument validation failed and similar "the model got it wrong" cases).
 * The loop encodes it as `{ok:false,error:{code,message}}`, feeds it back to the model and counts it as a
 * self-correction.
 */
export class ToolCallRejection extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'ToolCallRejection';
    this.code = code;
  }
}

/** What the loop should do after a tool execution failed. Decided by the entry per error type. */
export type ToolFailureDisposition =
  /** A failure that would hold for every later call too: the whole run throws. */
  | { kind: 'fatal' }
  /** A single failure: fed back as a structured `ok:false` and the loop continues; counts as a consecutive failure and the run throws at the threshold. */
  | { kind: 'degrade'; code: string; message: string }
  /**
   * Neutral result: fed back as a structured `ok:false` and the loop continues, but it **neither counts
   * as a consecutive failure nor resets the count**. For results where "the tool itself works, what the
   * model asked for just does not exist" (e.g. reading a deleted document): it is no evidence of an
   * origin / network fault and should not push the consecutive failures towards the breaker; nor is it
   * evidence of success that should wash away the count of earlier real faults. It still takes one tool
   * step (counts towards `maxSteps`).
   */
  | { kind: 'neutral'; code: string; message: string };

/** The execution context the loop hands to an entry. */
export interface ToolExecutionContext {
  /** Call id used for the feedback (a cross-leg unique fallback filled in by the loop when the upstream gave none). */
  callID: string;
  /** Ordinal of this tool step among those that **actually entered execution** in this run (starting at 1). */
  stepNumber: number;
  /** Index of the current leg (starting at 0). */
  legIndex: number;
  /**
   * Cancellation signal of this run (the user pressed stop). An entry must wire it to its own network
   * requests and waits: the loop only checks for cancellation between tools, an execution that has
   * already started must be aborted by the entry itself.
   */
  signal: AbortSignal;
}

/** Result of one successful execution. */
export interface ToolExecutionOutcome {
  /** Body of the tool message fed back to the model (already a JSON string or verbatim text). */
  content: string;
  /**
   * Whether to stop and wrap up after this execution (e.g. the library's "empty result limit"). When
   * non-empty the loop appends this system message, feeds the "stopped" error code (`stoppedErrorCode`)
   * back for the remaining tool_calls of the leg and then runs the tool-less synthesis leg.
   */
  stopReason?: string;
  /**
   * Text of the "stopped" error fed back for the **remaining** proposals when stopping; defaults to
   * `stopReason`. The library's "empty result limit" uses two different texts: the system message for the
   * model says "no evidence found, say so honestly", the skipped proposals get "empty result limit
   * reached".
   */
  stoppedMessage?: string;
}

/** A registry entry = one tool the generic loop can execute. `name` is the only allowlist key. */
export interface ToolRegistryEntry {
  readonly name: string;
  readonly scope: ToolScope;
  /**
   * The definition sent to the model; undefined for server-side built-in tools, whose definition is
   * injected into the request body by the recipe. Registration order = order of the tools sent to the model.
   */
  readonly definition?: ProxyToolDefinition;
  /** Executes. Throwing `ToolCallRejection` means the model got the arguments wrong; other errors go to `failureDisposition`. */
  execute(call: ProxyToolCall, context: ToolExecutionContext): Promise<ToolExecutionOutcome>;
  failureDisposition(error: unknown): ToolFailureDisposition;
}

/** The request of one model leg: full history + tool definitions + tool_choice. */
export interface ToolLoopLegRequest {
  messages: ProxyMessage[];
  tools: ProxyToolDefinition[];
  toolChoice: 'auto' | 'none';
}

/** Leg runner: send the request → parse the stream → emit events. Implementations must not handle tool_calls themselves (that is the loop's job). */
export type ToolLoopLegRunner = (request: ToolLoopLegRequest) => StreamHandle;

/**
 * Protocol adapter: encodes the loop's neutral results as each protocol's wire messages. On the web the
 * protocol translation happens when the request is built (request-builders); this only covers the two
 * messages the loop feeds back into the history. The default implementation is the openai_chat wire
 * shape.
 */
export interface ToolProtocolAdapter {
  encodeAssistantToolCalls(input: {
    text: string;
    toolCalls: ProxyToolCall[];
    continuation?: ContinuationIntent;
  }): ProxyMessage;
  encodeToolResult(input: { callID: string; toolName: string; content: string }): ProxyMessage;
}

export const openAIChatToolAdapter: ToolProtocolAdapter = {
  encodeAssistantToolCalls: ({ text, toolCalls, continuation }) => ({
    role: 'assistant',
    content: text,
    tool_calls: toolCalls,
    ...(continuation ? { providerContinuation: continuation } : {}),
  }),
  encodeToolResult: ({ callID, content }) => ({
    role: 'tool',
    tool_call_id: callID,
    content,
  }),
};

/**
 * The shared contract has a hard ceiling of 8; the effective value is min(configured value, 8),
 * defaulting to 6. Based on `client_tool_loop` in `shared/model-contracts/request_shape_contract.v2.json`.
 */
export const TOOL_LOOP_HARD_CAP = 8;
export const TOOL_LOOP_DEFAULT_MAX_STEPS = 6;

export function effectiveToolLoopMaxSteps(serverValue?: number | null): number {
  if (serverValue == null || !Number.isFinite(serverValue) || serverValue <= 0) {
    return TOOL_LOOP_DEFAULT_MAX_STEPS;
  }
  return Math.min(Math.floor(serverValue), TOOL_LOOP_HARD_CAP);
}

export interface ToolLoopLimits {
  /** Bounds both the number of legs and the number of successfully executed tool steps. */
  maxSteps: number;
  /** Limit of self-corrections for arguments the model got wrong (`ToolCallRejection`); beyond it the whole run throws. */
  maxSelfCorrections?: number;
  /** Consecutive tool **execution** failures reaching this threshold mean "not a transient blip" and the whole run throws. */
  maxConsecutiveToolFailures?: number;
  /** Cumulative token budget of this run; once reached, tool calling stops and the synthesis leg runs. undefined = unlimited. */
  tokenBudget?: number;
}

export const DEFAULT_MAX_SELF_CORRECTIONS = 3;
export const DEFAULT_MAX_CONSECUTIVE_TOOL_FAILURES = 3;

/**
 * Default error code fed back for skipped proposals when the loop wraps up early because of a limit.
 * The wording carries no feature flavour; the library passes its own `research_stopped` explicitly.
 */
export const DEFAULT_TOOL_LOOP_STOPPED_ERROR_CODE = 'tool_loop_stopped';

/**
 * The few fixed sentences fed back to the model. The defaults are neutral wording without any feature
 * flavour - the generic loop does not know whether the caller is doing "retrieval" or wants "cited
 * sources", and using the library's sentences as defaults would send the model of an MCP tool unrelated
 * instructions such as "cite sources as [n]". Features with their own voice pass them explicitly.
 */
export interface ToolLoopPrompts {
  stepLimitReached: string;
  tokenBudgetReached: string;
  stoppedByStepLimit: string;
  stoppedByTokenBudget: string;
}

export const defaultToolLoopPrompts: ToolLoopPrompts = {
  stepLimitReached:
    'The tool call limit was reached. Answer now using the tool results you already have. Do not call another tool.',
  tokenBudgetReached:
    'The token budget for tool calls was reached. Answer now using the tool results you already have and do not call another tool. If they are not enough to answer, say so clearly.',
  stoppedByStepLimit: 'The tool call step limit was reached.',
  stoppedByTokenBudget: 'The token budget for tool calls was reached.',
};

export type ToolLoopProgressEvent =
  /** A new leg starts (index from 0). Consumers reset per-leg state such as "text of this leg" on it. */
  | { type: 'legStarted'; legIndex: number }
  /** Text delta (within the current leg). */
  | { type: 'textDelta'; text: string }
  /** Reasoning delta. */
  | { type: 'reasoningDelta'; text: string }
  /** Cumulative usage (merged across legs). */
  | { type: 'usage'; usage: StreamUsage }
  /** The model's proposals of this leg are fully assembled and passed the allowlist (at least one hit the registry). */
  | { type: 'toolCallsAccepted'; calls: ProxyToolCall[] };

export interface ToolLoopResult {
  /** Text of the last leg (the synthesis leg / the leg where the model wrapped up on its own). */
  text: string;
  /** Text of every leg, in leg order. */
  legTexts: string[];
  usage?: StreamUsage;
  /**
   * The first leg answered directly without emitting a single tool call that **hit the registry**.
   * Only zero tool calls on the first leg means "silently did not retrieve"; zero tool calls on a later
   * leg means the evidence is in and the model is wrapping up.
   */
  endedWithoutToolCall: boolean;
  /** The step limit was hit (the user-facing progress view shows a trailing hint line). */
  stepLimitReached: boolean;
  /** Whether structured tool_calls ever appeared. */
  receivedStructuredToolCalls: boolean;
  executedToolSteps: number;
}

/** A model leg failed (an error event in the stream). `code` is the error code given by the upstream / classifier. */
export class ToolLoopError extends Error {
  readonly code: string;
  readonly source?: ProviderErrorSource;
  readonly streamStarted: boolean;
  /** Structured rejection context used by the no-tools fallback; provided by StreamHandle, may be empty. */
  readonly toolCallRejectionContext?: unknown;

  constructor(
    message: string,
    code: string,
    options: {
      source?: ProviderErrorSource;
      streamStarted?: boolean;
      toolCallRejectionContext?: unknown;
    } = {},
  ) {
    super(message);
    this.name = 'ToolLoopError';
    this.code = code;
    this.source = options.source;
    this.streamStarted = options.streamStarted ?? false;
    this.toolCallRejectionContext = options.toolCallRejectionContext;
  }
}
