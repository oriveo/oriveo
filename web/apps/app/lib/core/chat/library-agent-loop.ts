import type { ProviderErrorSource, ProviderKind } from "@oriveo/shared";
import type {
  StreamEvent,
  StreamHandle,
  StreamUsage,
} from "@oriveo/core/providers/types";
import type {
  ProxyMessage,
  ProxyToolCall,
  ProxyToolDefinition,
} from "@oriveo/core/providers/request-builders/runtime";
import type { ContinuationIntent } from '@oriveo/core/providers/request-preference/continuation';
import {
  finalizeToolCalls as finalizeAccumulatedToolCalls,
  mergeToolCallDeltas as mergeAccumulatedToolCallDeltas,
  type ToolCallAccumulator,
} from '@oriveo/core/providers/tool-call-accumulator';
import {
  LibraryAPIError,
  isLibraryNotFoundError,
  isLibraryRateLimitError,
} from "../library/api";
import type {
  LibraryCitation,
  LibraryConfirmationChoice,
  LibraryConfirmationRequest,
  LibraryListArgs,
  LibraryQuota,
  LibraryProvider,
  LibraryReadArgs,
  LibraryReadResult,
  LibraryResearchStep,
  LibraryRuntimeConfig,
  LibrarySearchArgs,
  LibrarySearchResult,
  LibraryToolArgs,
  LibraryToolName,
  LibraryToolResult,
} from "../library/types";
import { isDeterministicToolCallUnsupported } from './capability-recovery-runtime';

export interface LibraryAgentLegRequest {
  messages: ProxyMessage[];
  tools: ProxyToolDefinition[];
  toolChoice: "auto" | "none";
}

export interface LibraryAgentLoopResult {
  text: string;
  citations: LibraryCitation[];
  steps: LibraryResearchStep[];
  usage?: StreamUsage;
  /** D5: the first leg was explicitly resent once without tools and that resend succeeded. */
  toolFallbackApplied?: boolean;
}

/**
 * Fallback payload for a first leg that produced zero tool calls: the server retrieves the
 * evidence, injected exactly like the named-document path.
 */
export interface LibraryNoToolCallFallback {
  systemInstruction: string;
  userContext: string;
  citations: LibraryCitation[];
  steps: LibraryResearchStep[];
}

export interface LibraryAgentLoopOptions {
  messages: ProxyMessage[];
  config: LibraryRuntimeConfig;
  activeSources?: LibraryProvider[];
  modelContextLength?: number;
  signal: AbortSignal;
  runLeg: (request: LibraryAgentLegRequest) => StreamHandle;
  /** A connection-scoped D5 observation can suppress tools before the first leg. */
  toolsEnabled?: boolean;
  executeTool: (
    tool: LibraryToolName,
    args: LibraryToolArgs,
    toolCallId: string,
    signal: AbortSignal,
  ) => Promise<{ result: LibraryToolResult; quota?: LibraryQuota }>;
  requestConfirmation: (
    request: LibraryConfirmationRequest,
  ) => Promise<LibraryConfirmationChoice>;
  /**
   * Fallback hook for a first leg that returned zero tool calls.
   *
   * This scene used to be read as "the model chose not to search" and its first-leg text was
   * returned as the final answer, but it is exactly the signal that most needs a fallback: the model
   * is making the answer up while the user believes a search happened. Returning evidence discards
   * the first-leg text and re-answers from the server-retrieved evidence; returning null keeps the
   * current behaviour. Telemetry is the hook implementation's job, since only it knows the
   * provider and model.
   */
  onFirstLegWithoutToolCalls?: (
    legText: string,
  ) => Promise<LibraryNoToolCallFallback | null>;
  onSteps?: (steps: LibraryResearchStep[]) => void;
  onQuota?: (quota: LibraryQuota) => void;
  onUsage?: (usage: StreamUsage) => void;
  onText?: (text: string) => void;
}

export class LibraryResearchCancelledError extends Error {
  constructor() {
    super("Library research cancelled");
    this.name = "LibraryResearchCancelledError";
  }
}

export class LibraryAgentError extends Error {
  constructor(
    message: string,
    public readonly code = "library_source_error",
    public readonly source?: ProviderErrorSource,
    public readonly toolCallRejectionContext?: unknown,
    public readonly streamStarted = false,
  ) {
    super(message);
    this.name = "LibraryAgentError";
  }
}

const DEFAULT_LIBRARY_TOKEN_BUDGET = 8_000;

/**
 * How many consecutive tool failures count as "not a transient blip" and abort the whole turn.
 * Same shape as maxSelfCorrections (parameter-validation self-correction) but counted separately:
 * that one is the model writing bad arguments, this one is the source site or the network breaking,
 * and the sensible tolerances are unrelated. Three rather than a larger number, because the worst
 * case per failure is one watchdog period of waiting (toolTimeoutMs, 15s by default).
 */
const MAX_CONSECUTIVE_TOOL_FAILURES = 3;

export function buildLibraryTools(
  config: LibraryRuntimeConfig,
  activeSources: LibraryProvider[] = ["notion", "google"],
): ProxyToolDefinition[] {
  const sourceEnum = normalizeActiveSources(activeSources);
  return [
    {
      type: "function",
      function: {
        name: "library_search",
        description: config.toolDescriptions.library_search,
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            query: { type: "string", minLength: 1 },
            sources: {
              type: "array",
              items: { type: "string", enum: sourceEnum },
            },
            limit: { type: "integer", minimum: 1, maximum: 20 },
          },
          required: ["query"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "library_list",
        description: config.toolDescriptions.library_list,
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            source: { type: "string", enum: sourceEnum },
            containerId: { type: ["string", "null"] },
            cursor: { type: ["string", "null"] },
          },
          required: ["source"],
        },
      },
    },
    {
      type: "function",
      function: {
        name: "library_read",
        description: config.toolDescriptions.library_read,
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            docId: { type: "string", minLength: 1 },
            source: { type: "string", enum: sourceEnum },
            section: { type: ["string", "null"] },
            cursor: { type: ["string", "null"] },
          },
          required: ["docId", "source"],
        },
      },
    },
  ];
}

export async function runLibraryAgentLoop(
  options: LibraryAgentLoopOptions,
): Promise<LibraryAgentLoopResult> {
  const activeSources = normalizeActiveSources(
    options.activeSources ?? ["notion", "google"],
  );
  if (activeSources.length === 0) {
    throw new LibraryAgentError(
      "No active Library source is connected",
      "library_needs_reauth",
    );
  }
  const tools = buildLibraryTools(options.config, activeSources);
  const toolsEnabled = options.toolsEnabled !== false;
  const history = [...options.messages];
  const citations: LibraryCitation[] = [];
  const steps: LibraryResearchStep[] = [];
  let accumulatedUsage: StreamUsage | undefined;
  let selfCorrections = 0;
  let consecutiveToolFailures = 0;
  let emptyHits = 0;
  let requireListAfterEmptySearch = false;
  let forceSynthesis = false;
  let executedToolSteps = 0;
  // Sensitive-content confirmation for this retrieval: asked once even when several documents match, scoped to this run call.
  let sensitiveChoice: LibraryConfirmationChoice | undefined;
  const tokenBudget = resolveTokenBudget(
    options.config.tokenBudget,
    options.modelContextLength,
  );

  const emitSteps = () => options.onSteps?.(steps.map((step) => ({ ...step })));

  for (let legIndex = 0; legIndex < options.config.maxSteps; legIndex += 1) {
    throwIfAborted(options.signal);
    let toolFallbackApplied = false;
    let leg;
    try {
      leg = await consumeLeg(
        options.runLeg({
          messages: history,
          tools: toolsEnabled ? tools : [],
          toolChoice: toolsEnabled ? "auto" : "none",
        }),
        options.signal,
        options.onText,
        legIndex + 1,
      );
    } catch (error) {
      const eligible = legIndex === 0
        && toolsEnabled
        && error instanceof LibraryAgentError
        && error.source === 'provider'
        && !error.streamStarted
        && isDeterministicToolCallUnsupported(error.toolCallRejectionContext);
      if (!eligible) throw error;
      // D5 is deliberately depth=1. A failed resend surfaces as-is and never
      // records a negative capability observation.
      options.onText?.("");
      leg = await consumeLeg(
        options.runLeg({ messages: history, tools: [], toolChoice: "none" }),
        options.signal,
        options.onText,
        options.config.maxSteps + 1,
      );
      if (leg.toolCalls.length > 0) {
        throw new LibraryAgentError(
          'The no-tools fallback returned an unexpected tool call.',
          'library_invalid_tool_call',
          'provider',
        );
      }
      toolFallbackApplied = true;
    }
    accumulatedUsage = mergeUsage(accumulatedUsage, leg.usage);
    if (accumulatedUsage) options.onUsage?.(accumulatedUsage);

    if (leg.toolCalls.length === 0) {
      if (legIndex === 0 && toolsEnabled && !toolFallbackApplied && options.onFirstLegWithoutToolCalls) {
        // Wipe the first-leg text from the stream before fetching evidence: that text was made up
        // without any retrieval, and leaving it on screen while waiting presents a hallucination as the answer.
        options.onText?.("");
        const fallback = await options.onFirstLegWithoutToolCalls(leg.text);
        throwIfAborted(options.signal);
        if (fallback) {
          // The instruction goes into the leading system prompt and the evidence is appended to the
          // last user message, the same injection points the named-document path uses
          mergeLibrarySystemInstruction(history, fallback.systemInstruction);
          appendLibraryContextToLatestUser(history, fallback.userContext);
          const rerun = await consumeLeg(
            options.runLeg({ messages: history, tools, toolChoice: "none" }),
            options.signal,
            options.onText,
            options.config.maxSteps + 1,
          );
          accumulatedUsage = mergeUsage(accumulatedUsage, rerun.usage);
          if (accumulatedUsage) options.onUsage?.(accumulatedUsage);
          return {
            text: rerun.text,
            citations: fallback.citations,
            steps: fallback.steps,
            usage: accumulatedUsage,
          };
        }
        // No fallback available: hand the first-leg text back and keep the current behaviour
        options.onText?.(leg.text);
      }
      return {
        text: leg.text,
        citations: selectReferencedCitations(leg.text, citations),
        steps,
        usage: accumulatedUsage,
        ...(toolFallbackApplied ? { toolFallbackApplied: true } : {}),
      };
    }
    options.onText?.("");

    history.push({
      role: "assistant",
      content: leg.text,
      tool_calls: leg.toolCalls,
      ...(leg.providerContinuation ? { providerContinuation: leg.providerContinuation } : {}),
    });

    if (usageTotalTokens(accumulatedUsage) >= tokenBudget) {
      for (const call of leg.toolCalls) {
        history.push(
          toolResultMessage(call.id, {
            ok: false,
            error: {
              code: "research_stopped",
              message: "The Library research token budget was reached.",
            },
          }),
        );
      }
      history.push({
        role: "system",
        content:
          "The Library research token budget was reached. Synthesize the answer now from existing tool results, do not call another tool, and cite sources as [n]. If there is not enough evidence, say so clearly.",
      });
      forceSynthesis = true;
      break;
    }

    for (const [callIndex, call] of leg.toolCalls.entries()) {
      const validation = validateToolCall(
        call,
        requireListAfterEmptySearch,
        activeSources,
      );
      if (!validation.ok) {
        selfCorrections += 1;
        history.push(
          toolResultMessage(call.id, {
            ok: false,
            error: { code: validation.code, message: validation.message },
          }),
        );
        if (selfCorrections > options.config.maxSelfCorrections) {
          throw new LibraryAgentError(
            validation.message,
            "library_invalid_tool_call",
          );
        }
        continue;
      }

      const { tool, args } = validation;
      const stepNumber = executedToolSteps + 1;
      executedToolSteps = stepNumber;
      const step: LibraryResearchStep = {
        id: `${stepNumber}:${call.id}`,
        tool,
        label: buildStepLabel(tool, args),
        status: "running",
        step: stepNumber,
      };
      steps.push(step);
      emitSteps();

      try {
        const response = await executeWithRetry(options, tool, args, call.id);
        consecutiveToolFailures = 0;
        if (response.quota) options.onQuota?.(response.quota);
        let result = response.result;
        let reachedEmptyLimit = false;

        if (tool === "library_search") {
          const count = Array.isArray((result as LibrarySearchResult).hits)
            ? (result as LibrarySearchResult).hits.length
            : 0;
          if (count === 0) {
            emptyHits += 1;
            requireListAfterEmptySearch = true;
            reachedEmptyLimit = emptyHits >= options.config.maxEmptyHits;
          } else {
            emptyHits = 0;
            requireListAfterEmptySearch = false;
          }
        } else if (tool === "library_list") {
          requireListAfterEmptySearch = false;
        }

        if (tool === "library_read") {
          let read = result as LibraryReadResult;
          const sensitiveRead = read.sensitive?.hit === true;
          if (sensitiveRead && !hasServerRedactedRead(read)) {
            throw new LibraryAgentError(
              "The Library response did not include a server-redacted payload.",
              "library_redaction_unavailable",
            );
          }
          const citationRead = sensitiveRead
            ? applyServerRedactedLibraryRead(read)
            : read;
          const confirmation = buildLibraryReadConfirmation(
            read,
            args as LibraryReadArgs,
            options.config,
          );
          if (confirmation) {
            // One retrieval may read three to five documents, and prompting per document would
            // stack dialogs on the send path while the user clearly has a single opinion about the
            // whole batch. The choice is reused only inside this loop (a local variable that dies
            // with the run) and never across messages.
            if (!sensitiveChoice) {
              sensitiveChoice = await options.requestConfirmation(confirmation);
              throwIfAborted(options.signal);
            }
            if (sensitiveChoice === "cancel") {
              step.status = "failed";
              emitSteps();
              throw new LibraryResearchCancelledError();
            }
            if (sensitiveChoice === "redact") {
              read = applyServerRedactedLibraryRead(read);
            }
          }
          const citationIndex = addCitation(
            citations,
            citationRead,
            args as LibraryReadArgs,
          );
          result = citationIndex == null ? read : { ...read, citationIndex };
        }

        history.push(
          toolResultMessage(call.id, {
            ok: true,
            result,
            ...(tool === "library_search" && requireListAfterEmptySearch
              ? {
                  requiredNextTool: "library_list",
                  instruction:
                    "Search returned no results. Call library_list next.",
                }
              : {}),
          }),
        );
        step.status = "completed";
        emitSteps();

        if (reachedEmptyLimit) {
          forceSynthesis = true;
          history.push({
            role: "system",
            content:
              "No relevant Library evidence was found. Answer honestly that nothing was found and do not invent facts.",
          });
          for (const skipped of leg.toolCalls.slice(callIndex + 1)) {
            history.push(
              toolResultMessage(skipped.id, {
                ok: false,
                error: {
                  code: "research_stopped",
                  message: "The empty-result limit was reached.",
                },
              }),
            );
          }
          break;
        }
      } catch (error) {
        if (error instanceof LibraryResearchCancelledError) throw error;
        if (isLibraryNotFoundError(error)) {
          history.push(
            toolResultMessage(call.id, {
              ok: false,
              error: {
                code: "library_not_found",
                message:
                  "The requested Library document was not found. Do not invent its contents; use other evidence or say it was not found.",
              },
            }),
          );
          // This step genuinely failed to read any evidence, so it is marked failed rather than
          // completed.
          step.status = "failed";
          emitSteps();
        } else if (isFatalLibraryToolError(error)) {
          // Account-level failures: the connection needs re-authorisation, the monthly quota is
          // exhausted, the retrieval step ceiling was hit, or the redacted payload is missing.
          // Calling the tool again only burns requests and buries the card the user actually needs
          // to see inside a tool result, which the model paraphrases as "I cannot reach the library".
          step.status = "failed";
          emitSteps();
          throw error;
        } else {
          // A single tool failure, watchdog timeouts included, drops only that call instead of
          // aborting the turn: the model moves on to other evidence and can still produce a cited
          // answer. Aborting turns the whole message into an error card and throws away every piece
          // of evidence already gathered because one document could not be read.
          consecutiveToolFailures += 1;
          history.push(
            toolResultMessage(call.id, {
              ok: false,
              error: {
                code: toolFailureCode(error),
                message:
                  "The Library tool call failed. Do not invent its contents; use other evidence or say the source was unavailable.",
              },
            }),
          );
          step.status = "failed";
          emitSteps();
          // Reaching the consecutive-failure threshold means this is not a transient blip (the
          // source site is down, or the network is), and feeding more calls only costs watchdog periods.
          if (consecutiveToolFailures >= MAX_CONSECUTIVE_TOOL_FAILURES) {
            throw error;
          }
        }
      }

      if (executedToolSteps >= options.config.maxSteps) {
        for (const skipped of leg.toolCalls.slice(callIndex + 1)) {
          history.push(
            toolResultMessage(skipped.id, {
              ok: false,
              error: {
                code: "research_stopped",
                message: "The Library research step limit was reached.",
              },
            }),
          );
        }
        history.push({
          role: "system",
          content:
            "The Library research step limit was reached. Synthesize the answer now from existing tool results. Do not call another tool and cite sources as [n].",
        });
        forceSynthesis = true;
        break;
      }
    }
    if (forceSynthesis) break;
  }

  if (!forceSynthesis) {
    history.push({
      role: "system",
      content:
        "The Library research step limit was reached. Synthesize the answer now from existing tool results. Do not call another tool and cite sources as [n].",
    });
  }
  const finalLeg = await consumeLeg(
    options.runLeg({ messages: history, tools, toolChoice: "none" }),
    options.signal,
    options.onText,
    options.config.maxSteps + 1,
  );
  accumulatedUsage = mergeUsage(accumulatedUsage, finalLeg.usage);
  if (accumulatedUsage) options.onUsage?.(accumulatedUsage);
  return {
    text: finalLeg.text,
    citations: selectReferencedCitations(finalLeg.text, citations),
    steps,
    usage: accumulatedUsage,
  };
}

async function consumeLeg(
  handle: StreamHandle,
  signal: AbortSignal,
  onText?: (text: string) => void,
  fallbackNamespace = 1,
): Promise<{
  text: string;
  toolCalls: ProxyToolCall[];
  usage?: StreamUsage;
  providerContinuation?: ContinuationIntent;
}> {
  const onAbort = () => handle.abort();
  signal.addEventListener("abort", onAbort, { once: true });
  const reader = handle.stream.getReader();
  let text = "";
  let usage: StreamUsage | undefined;
  const accumulated: ToolCallAccumulator = new Map();
  let providerContinuation: ContinuationIntent | undefined;
  let streamStarted = false;
  try {
    while (true) {
      throwIfAborted(signal);
      const next = await reader.read();
      throwIfAborted(signal);
      if (next.done) break;
      const event: StreamEvent = next.value;
      if (event.type !== 'error') streamStarted = true;
      if (event.type === "delta") {
        text += event.content;
        onText?.(text);
      } else if (event.type === "tool_calls")
        mergeAccumulatedToolCallDeltas(accumulated, event.toolCalls);
      else if (event.type === "usage") usage = event.usage;
      else if (event.type === 'continuation') providerContinuation = event.continuation;
      else if (event.type === "error")
        throw new LibraryAgentError(
          event.error,
          event.errorKind,
          event.source,
          handle.getToolCallRejectionContext?.(),
          streamStarted,
        );
    }
  } finally {
    signal.removeEventListener("abort", onAbort);
    reader.releaseLock();
  }
  return {
    text,
    toolCalls: finalizeAccumulatedToolCalls(accumulated, `library_call_${fallbackNamespace}`)
      .map((call) => ({
        id: call.id,
        type: 'function' as const,
        function: { name: call.name, arguments: call.arguments },
      })),
    usage,
    providerContinuation,
  };
}

function validateToolCall(
  call: ProxyToolCall,
  requireList: boolean,
  activeSources: LibraryProvider[],
):
  | { ok: true; tool: LibraryToolName; args: LibraryToolArgs }
  | { ok: false; code: string; message: string } {
  const tool = call.function.name as LibraryToolName;
  if (
    tool !== "library_search" &&
    tool !== "library_list" &&
    tool !== "library_read"
  ) {
    return {
      ok: false,
      code: "unknown_tool",
      message: `Unsupported Library tool: ${call.function.name}`,
    };
  }
  if (requireList && tool !== "library_list") {
    return {
      ok: false,
      code: "list_fallback_required",
      message: "library_list is required after an empty search.",
    };
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(call.function.arguments);
  } catch {
    return {
      ok: false,
      code: "invalid_arguments",
      message: "Tool arguments must be valid JSON.",
    };
  }
  if (!isRecord(parsed))
    return {
      ok: false,
      code: "invalid_arguments",
      message: "Tool arguments must be an object.",
    };
  if (tool === "library_search") {
    if (typeof parsed.query !== "string" || !parsed.query.trim()) {
      return {
        ok: false,
        code: "invalid_arguments",
        message: "library_search requires a non-empty query.",
      };
    }
    if (
      parsed.sources !== undefined &&
      (!Array.isArray(parsed.sources) ||
        parsed.sources.some(
          (source) => !isSource(source) || !activeSources.includes(source),
        ))
    ) {
      return {
        ok: false,
        code: "source_not_connected",
        message: "library_search sources must be currently connected.",
      };
    }
    return { ok: true, tool, args: parsed as unknown as LibrarySearchArgs };
  }
  if (tool === "library_list") {
    if (!isSource(parsed.source) || !activeSources.includes(parsed.source))
      return {
        ok: false,
        code: "invalid_arguments",
        message: "library_list requires a valid source.",
      };
    return { ok: true, tool, args: parsed as unknown as LibraryListArgs };
  }
  if (
    typeof parsed.docId !== "string" ||
    !parsed.docId.trim() ||
    !isSource(parsed.source) ||
    !activeSources.includes(parsed.source)
  ) {
    return {
      ok: false,
      code: "invalid_arguments",
      message: "library_read requires docId and source.",
    };
  }
  return { ok: true, tool, args: parsed as unknown as LibraryReadArgs };
}

function normalizeActiveSources(sources: LibraryProvider[]): LibraryProvider[] {
  return [...new Set(sources.filter(isSource))];
}

async function executeWithRetry(
  options: LibraryAgentLoopOptions,
  tool: LibraryToolName,
  args: LibraryToolArgs,
  toolCallId: string,
): Promise<{ result: LibraryToolResult; quota?: LibraryQuota }> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const controller = new AbortController();
    const onAbort = () => controller.abort();
    options.signal.addEventListener("abort", onAbort, { once: true });
    const timer = globalThis.setTimeout(
      () => controller.abort(),
      options.config.toolTimeoutMs,
    );
    try {
      return await options.executeTool(tool, args, toolCallId, controller.signal);
    } catch (error) {
      if (error instanceof LibraryAPIError && error.quota) {
        options.onQuota?.(error.quota);
      }
      if (isLibraryRateLimitError(error)) {
        if (attempt === 0 && !options.signal.aborted) {
          await abortableDelay(
            Math.min(5_000, Math.max(250, ((error as LibraryAPIError).retryAfter ?? 1) * 1_000)),
            options.signal,
          );
          continue;
        }
      }
      if (controller.signal.aborted && !options.signal.aborted) {
        throw new LibraryAgentError(
          "Library tool request timed out",
          "library_timeout",
        );
      }
      throw error;
    } finally {
      globalThis.clearTimeout(timer);
      options.signal.removeEventListener("abort", onAbort);
    }
  }
  throw new LibraryAgentError(
    "Library tool retry exhausted",
    "library_rate_limited",
  );
}

/**
 * Whether this tool failure should abort the whole turn.
 *
 * Only account-level failures, plus a missing redacted payload for privacy reasons, are fatal: they
 * hold for every subsequent call, so continuing to feed ok:false wastes requests and hides cards the
 * user must see, such as re-authorise or monthly quota exhausted, inside a tool result. Everything
 * else (source-site 5xx, exhausted rate limits, watchdog timeouts) is a single-call or
 * single-document incident and degrades gracefully.
 */
function isFatalLibraryToolError(error: unknown): boolean {
  const code = toolFailureCode(error);
  return (
    code === "library_needs_reauth" ||
    code === "library_quota_exceeded" ||
    code === "library_research_step_limit" ||
    code === "library_redaction_unavailable"
  );
}

/** Error code returned to the model in a degraded tool result; the same codes the failure cards use, so logs line up. */
function toolFailureCode(error: unknown): string {
  if (error instanceof LibraryAgentError) return error.code;
  if (error instanceof LibraryAPIError) return error.code ?? "library_source_error";
  return "library_source_error";
}

export function buildLibraryReadConfirmation(
  result: LibraryReadResult,
  args: LibraryReadArgs,
  config: LibraryRuntimeConfig,
): LibraryConfirmationRequest | null {
  // Only the sensitive gate is left.
  //
  // The server judged `broad_read` by "no section specified", but reading a whole document is the
  // normal case here (named, server-picked and agent-chosen reads all leave section empty), so it
  // fired on 100% of the normal path: picking three documents meant three "this will read a large
  // range" dialogs whose only rational answer was OK. The server does not emit it any more (audit
  // only), so the branch goes away here too.
  // `high_cost` was never emitted for read, so that branch was dead from the start.
  // sensitive stays: it offers a real second option, continuing with redaction.
  const sensitive = config.sensitiveGateEnabled && result.sensitive?.hit;
  if (!sensitive) return null;
  return {
    id: `confirm:${args.source}:${args.docId}:${Date.now()}`,
    reason: "sensitive" as const,
    detail: {
      kinds: result.sensitive?.kinds,
      docTitles: result.redacted?.title ? [result.redacted.title] : undefined,
    },
  };
}

function hasServerRedactedRead(result: LibraryReadResult): boolean {
  return Boolean(
    result.redacted &&
    typeof result.redacted.title === "string" &&
    Array.isArray(result.redacted.sections),
  );
}

export function applyServerRedactedLibraryRead(result: LibraryReadResult): LibraryReadResult {
  if (!hasServerRedactedRead(result)) {
    throw new LibraryAgentError(
      "The Library response did not include a server-redacted payload.",
      "library_redaction_unavailable",
    );
  }
  return {
    ...result,
    title: result.redacted!.title,
    sections: result.redacted!.sections,
    sensitive: result.sensitive
      ? { ...result.sensitive, hit: false }
      : undefined,
  };
}

/**
 * A citation carries document identity only.
 *
 * Deliberately no body excerpt: citations land in message storage and are synced by
 * sync-mappings, while the privacy policy promises that document bodies and snippets never enter
 * message storage and never sync across clients. The other two paths (server retrieval and named
 * document) store no excerpts, so the agent path would be the only leak.
 *
 * Same for the section anchor: the citation field whitelist is docId / source / title / url /
 * lastEdited, no client UI consumes an anchor, and storing it only widens the persisted and synced
 * field surface for nothing. Not to be confused with the `<section anchor="...">` in the envelope,
 * which lives only inside this outbound request and stays.
 */
export function createLibraryCitation(
  result: LibraryReadResult,
  args: LibraryReadArgs,
  index: number,
): LibraryCitation | undefined {
  if (!result.url || !isTrustedLibraryURL(result.url, args.source))
    return undefined;
  return {
    index,
    url: result.url,
    title: result.title,
    docId: result.docId || args.docId,
    source: args.source,
    lastEdited: result.lastEdited,
  };
}

function addCitation(
  target: LibraryCitation[],
  result: LibraryReadResult,
  args: LibraryReadArgs,
): number | undefined {
  if (!result.url || !isTrustedLibraryURL(result.url, args.source))
    return undefined;
  const docId = result.docId || args.docId;
  const existing = target.find(
    (citation) => citation.docId === docId && citation.source === args.source,
  );
  if (existing) return existing.index;
  const index = target.length + 1;
  const citation = createLibraryCitation(result, args, index);
  if (!citation) return undefined;
  target.push(citation);
  return index;
}

function mergeUsage(
  current: StreamUsage | undefined,
  next: StreamUsage | undefined,
): StreamUsage | undefined {
  if (!next) return current;
  if (!current) return next;
  const sumOptional = (left: number | undefined, right: number | undefined) =>
    left == null && right == null ? undefined : (left ?? 0) + (right ?? 0);
  const leftBreakdown = current.breakdown;
  const rightBreakdown = next.breakdown;
  return {
    prompt_tokens: sumOptional(current.prompt_tokens, next.prompt_tokens),
    completion_tokens: sumOptional(
      current.completion_tokens,
      next.completion_tokens,
    ),
    total_tokens: sumOptional(current.total_tokens, next.total_tokens),
    breakdown:
      leftBreakdown || rightBreakdown
        ? {
            promptTokens:
              (leftBreakdown?.promptTokens ?? 0) +
              (rightBreakdown?.promptTokens ?? 0),
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
              (leftBreakdown?.reasoningTokens ?? 0) +
              (rightBreakdown?.reasoningTokens ?? 0),
            upstreamCost: sumOptional(
              leftBreakdown?.upstreamCost,
              rightBreakdown?.upstreamCost,
            ),
            // The observation flags must follow the leg: if any leg's upstream explicitly reported
            // cache figures, a 0 in the accumulated result is the real fact "no cache hit this
            // time", not "upstream reported nothing". Dropping these two keys makes
            // cacheReadObserved undefined after a multi-leg retrieval where every leg dutifully
            // returned cached_tokens: 0, both branches of deriveCostFields then read false and the
            // cache row is not rendered at all, whereas a present raw usage path must be persisted
            // and displayed even when the value is 0.
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

function resolveTokenBudget(
  configuredBudget: number,
  modelContextLength: number | undefined,
): number {
  if (Number.isFinite(configuredBudget) && configuredBudget > 0)
    return Math.floor(configuredBudget);
  if (
    typeof modelContextLength === "number" &&
    Number.isFinite(modelContextLength) &&
    modelContextLength > 0
  ) {
    return Math.floor(modelContextLength);
  }
  return DEFAULT_LIBRARY_TOKEN_BUDGET;
}

function usageTotalTokens(usage: StreamUsage | undefined): number {
  if (!usage) return 0;
  const componentTotal =
    (usage.prompt_tokens ?? 0) + (usage.completion_tokens ?? 0);
  if (
    typeof usage.total_tokens === "number" &&
    Number.isFinite(usage.total_tokens)
  ) {
    return Math.max(usage.total_tokens, componentTotal);
  }
  return componentTotal;
}

function selectReferencedCitations(
  text: string,
  citations: LibraryCitation[],
): LibraryCitation[] {
  const referenced = new Set<number>();
  for (const match of text.matchAll(/\[(\d+)]/g))
    referenced.add(Number(match[1]));
  return citations.filter(
    (citation) => citation.index != null && referenced.has(citation.index),
  );
}

function buildStepLabel(tool: LibraryToolName, args: LibraryToolArgs): string {
  if (tool === "library_search") return (args as LibrarySearchArgs).query;
  if (tool === "library_read")
    return (args as LibraryReadArgs).section || (args as LibraryReadArgs).docId;
  return (
    (args as LibraryListArgs).containerId || (args as LibraryListArgs).source
  );
}

function mergeLibrarySystemInstruction(
  messages: ProxyMessage[],
  instruction: string,
): void {
  const head = messages[0];
  if (head?.role === "system" && typeof head.content === "string") {
    messages[0] = { ...head, content: `${head.content}\n\n${instruction}` };
    return;
  }
  messages.unshift({ role: "system", content: instruction });
}

/**
 * Appends the evidence to the last user message, the same position the named-document path uses:
 * the evidence sits next to the question so the model does not mistake it for leftover context.
 */
function appendLibraryContextToLatestUser(
  messages: ProxyMessage[],
  text: string,
): void {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message.role !== "user") continue;
    const content = message.content;
    messages[index] = {
      ...message,
      content: typeof content === "string"
        ? `${content}\n\n${text}`
        : [...content, { type: "text", text: `\n\n${text}` }],
    };
    return;
  }
}

function toolResultMessage(toolCallID: string, payload: unknown): ProxyMessage {
  return {
    role: "tool",
    tool_call_id: toolCallID,
    content: JSON.stringify(payload),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSource(value: unknown): value is "notion" | "google" {
  return value === "notion" || value === "google";
}

/**
 * Rebuilds the canonical source URL of a document from its docId.
 *
 * Notion and Google document addresses can be composed straight from the id, so a citation need not
 * degrade to an unclickable `library-context://` when the server returns no trusted URL. An id that
 * does not match the expected shape returns undefined: better the pseudo-protocol than a guessed
 * address that 404s.
 */
export function canonicalLibraryURL(
  docId: string,
  source: "notion" | "google",
): string | undefined {
  const trimmed = docId.trim();
  if (!trimmed) return undefined;
  if (source === "notion") {
    // Notion page and data_source ids are 32 hex characters, with or without hyphens
    const compact = trimmed.replace(/-/g, "");
    if (!/^[0-9a-fA-F]{32}$/.test(compact)) return undefined;
    return `https://www.notion.so/${compact}`;
  }
  return `https://drive.google.com/open?id=${encodeURIComponent(trimmed)}`;
}

/** Final URL for a document citation: trusted original URL, then docId reconstruction, then the pseudo-protocol fallback. */
export function resolveLibraryCitationURL(
  rawURL: string | undefined,
  docId: string,
  source: "notion" | "google",
): string {
  if (rawURL && isTrustedLibraryURL(rawURL, source)) return rawURL;
  return (
    canonicalLibraryURL(docId, source) ??
    `library-context://${source}/${encodeURIComponent(docId)}`
  );
}

export function isTrustedLibraryURL(
  raw: string,
  source: "notion" | "google",
): boolean {
  try {
    const url = new URL(raw);
    if (url.protocol !== "https:") return false;
    if (source === "notion")
      return (
        url.hostname === "notion.so" || url.hostname.endsWith(".notion.so")
      );
    return (
      url.hostname === "docs.google.com" || url.hostname === "drive.google.com"
    );
  } catch {
    return false;
  }
}

function throwIfAborted(signal: AbortSignal): void {
  if (signal.aborted) throw new DOMException("Aborted", "AbortError");
}

function abortableDelay(ms: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) {
    return Promise.reject(new DOMException("Aborted", "AbortError"));
  }
  if (ms <= 0) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      globalThis.clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      reject(new DOMException("Aborted", "AbortError"));
    };
    const timer = globalThis.setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal.addEventListener("abort", onAbort, { once: true });
  });
}
