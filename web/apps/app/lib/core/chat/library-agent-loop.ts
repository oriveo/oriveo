import type { ProviderErrorSource } from "@oriveo/shared";
import type {
  StreamHandle,
  StreamUsage,
} from "@oriveo/core/providers/types";
import type {
  ProxyMessage,
  ProxyToolCall,
  ProxyToolDefinition,
} from "@oriveo/core/providers/request-builders/runtime";
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
import { ToolCallLoop, type ToolCallLoopOptions } from "@oriveo/core/tools/tool-call-loop";
import {
  ToolCallRejection,
  ToolLoopError,
  type ToolExecutionContext,
  type ToolExecutionOutcome,
  type ToolFailureDisposition,
  type ToolLoopProgressEvent,
  type ToolLoopPrompts,
  type ToolLoopResult,
  type ToolRegistryEntry,
} from "@oriveo/core/tools/tool-loop-contracts";
import { ToolRegistry } from "@oriveo/core/tools/tool-registry";
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
  /**
   * Entries from other sources that are on for the same reply (the library and remote MCP share one
   * loop and one step limit), registered after the three library tools. When non-empty, the
   * consecutive-failure breaker is off: MCP failures always degrade, and an error from one
   * third-party server must not take down the whole reply.
   */
  additionalEntries?: readonly ToolRegistryEntry[];
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

/** The fixed library wording the generic loop feeds back to the model. */
const LIBRARY_LOOP_PROMPTS: ToolLoopPrompts = {
  stepLimitReached:
    "The Library research step limit was reached. Synthesize the answer now from existing tool results. Do not call another tool and cite sources as [n].",
  tokenBudgetReached:
    "The Library research token budget was reached. Synthesize the answer now from existing tool results, do not call another tool, and cite sources as [n]. If there is not enough evidence, say so clearly.",
  stoppedByStepLimit: "The Library research step limit was reached.",
  stoppedByTokenBudget: "The Library research token budget was reached.",
};

/** Error code fed back for a proposal that was skipped (the generic loop's default is a different, neutral code). */
const LIBRARY_LOOP_STOPPED_ERROR_CODE = "research_stopped";

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

/**
 * Session state of one agentic library research run. It lives for a single run only: the loop
 * executes tools serially, so these fields are never written concurrently.
 */
interface LibraryLoopState {
  citations: LibraryCitation[];
  steps: LibraryResearchStep[];
  emptyHits: number;
  requireListAfterEmptySearch: boolean;
  /** The sensitive-content choice for this run: several hits ask only once, and the choice is scoped to this one run. */
  sensitiveChoice?: LibraryConfirmationChoice;
}

/**
 * Entry point of agentic library research: it assembles the registry and the generic loop. Every
 * library-specific policy (argument validation, forcing a list after an empty search, the sensitive
 * gate, the citation ledger, the injection budget, the watchdog and rate-limit retry, the fatal or
 * degrade verdict) lives in the registry entries and in the callbacks of this wrapper.
 */
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
  const toolsEnabled = options.toolsEnabled !== false;
  const state: LibraryLoopState = {
    citations: [],
    steps: [],
    emptyHits: 0,
    requireListAfterEmptySearch: false,
  };
  const emitSteps = () => options.onSteps?.(state.steps.map((step) => ({ ...step })));
  const additionalEntries = options.additionalEntries ?? [];
  const registry = new ToolRegistry([
    ...buildLibraryTools(options.config, activeSources).map((definition) =>
      createLibraryEntry(
        definition.function.name as LibraryToolName,
        definition,
        activeSources,
        options,
        state,
        emitSteps,
      ),
    ),
    ...additionalEntries,
  ]);

  // Cumulative snapshot of this leg's text: progress events carry deltas, while the callback wants the running total.
  let legText = "";
  // The no-tools resend needs to know which leg failed: only the first leg (0) may be resent.
  let activeLegIndex = 0;
  const onProgress = (event: ToolLoopProgressEvent): void => {
    switch (event.type) {
      case "legStarted":
        activeLegIndex = event.legIndex;
        legText = "";
        break;
      case "textDelta":
        legText += event.text;
        options.onText?.(legText);
        break;
      case "usage":
        options.onUsage?.(event.usage);
        break;
      case "toolCallsAccepted":
        // Once a leg with tool calls has passed, the text is cleared and the next leg renders from the start.
        options.onText?.("");
        break;
      default:
        break;
    }
  };

  const fallbackRef: { value: LibraryNoToolCallFallback | null } = { value: null };
  const firstLegHook = options.onFirstLegWithoutToolCalls;
  let toolFallbackApplied = false;

  const limits: ToolCallLoopOptions["limits"] = {
    maxSteps: options.config.maxSteps,
    maxSelfCorrections: options.config.maxSelfCorrections,
    maxConsecutiveToolFailures: additionalEntries.length > 0
      ? Number.POSITIVE_INFINITY
      : MAX_CONSECUTIVE_TOOL_FAILURES,
    tokenBudget: resolveTokenBudget(
      options.config.tokenBudget,
      options.modelContextLength,
    ),
  };
  const loopOptions: ToolCallLoopOptions = {
    registry,
    runLeg: options.runLeg,
    signal: options.signal,
    limits,
    prompts: LIBRARY_LOOP_PROMPTS,
    stoppedErrorCode: LIBRARY_LOOP_STOPPED_ERROR_CODE,
    // Fallback namespace for proposals with an empty ID, numbered across legs as library_call_<leg>_<index>.
    callIdFallbackPrefix: "library_call",
    // A tool name outside the registry counts as a self-correction, like a wrong argument, and research goes on rather than ending silently.
    unhandledToolCalls: "selfCorrect",
    // With MCP on as well, the registry holds more than library tools, so the wording is not limited to "Library".
    unknownToolMessage: (name) => additionalEntries.length > 0
      ? `Unsupported tool: ${name}`
      : `Unsupported Library tool: ${name}`,
    ...(toolsEnabled ? {} : { toolsMode: "disabled" as const }),
    ...(toolsEnabled && firstLegHook
      ? {
          onFirstLegWithoutToolCalls: async (text: string) => {
            // Remove the first leg's text from the stream before fetching evidence: the model made
            // it up without searching, and leaving it on screen while waiting would present a
            // hallucination as the answer.
            options.onText?.("");
            const resolved = await firstLegHook(text);
            throwIfAborted(options.signal);
            if (resolved) {
              fallbackRef.value = resolved;
              // The instruction is merged into the leading system prompt and the evidence is
              // appended to the last user message, the same positions the named-documents path uses.
              const injected = [...options.messages];
              mergeLibrarySystemInstruction(injected, resolved.systemInstruction);
              appendLibraryContextToLatestUser(injected, resolved.userContext);
              return injected;
            }
            // The fallback is unavailable: put the first leg's text back and leave things as they are.
            options.onText?.(text);
            return null;
          },
        }
      : {}),
  };

  let result: ToolLoopResult;
  try {
    result = await new ToolCallLoop(loopOptions).run(options.messages, onProgress);
  } catch (error) {
    const toolError = error instanceof ToolLoopError ? error : null;
    const eligible = toolsEnabled
      && activeLegIndex === 0
      && toolError !== null
      && toolError.source === "provider"
      && !toolError.streamStarted
      && isDeterministicToolCallUnsupported(toolError.toolCallRejectionContext);
    if (!eligible) throw toLibraryAgentError(error);
    // The resend is deliberately depth 1: a resend that fails is rethrown as is, with no recursion and no negative capability observation.
    options.onText?.("");
    result = await resendWithoutTools(options, limits, onProgress);
    toolFallbackApplied = true;
  }

  if (fallbackRef.value) {
    const fallback = fallbackRef.value;
    return {
      text: result.text,
      citations: fallback.citations,
      steps: fallback.steps,
      usage: result.usage,
    };
  }
  return {
    text: result.text,
    citations: selectReferencedCitations(result.text, state.citations),
    steps: state.steps,
    usage: result.usage,
    ...(toolFallbackApplied ? { toolFallbackApplied: true } : {}),
  };
}

/**
 * The one-off resend without tools: an empty registry plus `toolsMode: disabled` (tools=[] and
 * tool_choice=none on every leg). If the model still proposes a call, `library_invalid_tool_call`
 * is thrown as is, without another resend.
 */
async function resendWithoutTools(
  options: LibraryAgentLoopOptions,
  limits: ToolCallLoopOptions["limits"],
  onProgress: (event: ToolLoopProgressEvent) => void,
): Promise<ToolLoopResult> {
  try {
    return await new ToolCallLoop({
      registry: ToolRegistry.empty,
      runLeg: options.runLeg,
      signal: options.signal,
      limits,
      prompts: LIBRARY_LOOP_PROMPTS,
      stoppedErrorCode: LIBRARY_LOOP_STOPPED_ERROR_CODE,
      callIdFallbackPrefix: "library_call",
      toolsMode: "disabled",
      onUnhandledToolCalls: () => {
        throw new LibraryAgentError(
          "The no-tools fallback returned an unexpected tool call.",
          "library_invalid_tool_call",
          "provider",
        );
      },
    }).run(options.messages, onProgress);
  } catch (error) {
    throw toLibraryAgentError(error);
  }
}

/** One library tool is one registry entry; execution is delegated entirely to this run's session state. */
function createLibraryEntry(
  tool: LibraryToolName,
  definition: ProxyToolDefinition,
  activeSources: LibraryProvider[],
  options: LibraryAgentLoopOptions,
  state: LibraryLoopState,
  emitSteps: () => void,
): ToolRegistryEntry {
  return {
    name: tool,
    scope: "library",
    definition,
    execute: (call, context) =>
      executeLibraryToolCall(
        tool,
        call,
        context,
        activeSources,
        options,
        state,
        emitSteps,
      ),
    failureDisposition: libraryFailureDisposition,
  };
}

async function executeLibraryToolCall(
  tool: LibraryToolName,
  call: ProxyToolCall,
  context: ToolExecutionContext,
  activeSources: LibraryProvider[],
  options: LibraryAgentLoopOptions,
  state: LibraryLoopState,
  emitSteps: () => void,
): Promise<ToolExecutionOutcome> {
  const validation = validateToolCall(
    call,
    state.requireListAfterEmptySearch,
    activeSources,
  );
  if (!validation.ok) {
    // A wrong argument, source or tool name all count as a model self-correction: no step is created and nothing is executed.
    throw new ToolCallRejection(validation.code, validation.message);
  }
  const args = validation.args;
  const stepNumber = context.stepNumber;
  const step: LibraryResearchStep = {
    id: `${stepNumber}:${call.id}`,
    tool,
    label: buildStepLabel(tool, args),
    status: "running",
    step: stepNumber,
  };
  state.steps.push(step);
  emitSteps();

  try {
    const response = await executeWithRetry(options, tool, args, call.id);
    if (response.quota) options.onQuota?.(response.quota);
    let result = response.result;
    let stopReason: string | undefined;

    if (tool === "library_search") {
      const count = Array.isArray((result as LibrarySearchResult).hits)
        ? (result as LibrarySearchResult).hits.length
        : 0;
      if (count === 0) {
        state.emptyHits += 1;
        state.requireListAfterEmptySearch = true;
        if (state.emptyHits >= options.config.maxEmptyHits) {
          stopReason =
            "No relevant Library evidence was found. Answer honestly that nothing was found and do not invent facts.";
        }
      } else {
        state.emptyHits = 0;
        state.requireListAfterEmptySearch = false;
      }
    } else if (tool === "library_list") {
      state.requireListAfterEmptySearch = false;
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
        // The model may read three to five documents in one run. Asking per document would pile
        // dialogs onto the send path, while the user's stance on this batch of evidence is clearly
        // one and the same. The choice is reused within this loop only (the session state goes away
        // when the run ends) and never across messages.
        if (!state.sensitiveChoice) {
          state.sensitiveChoice = await options.requestConfirmation(confirmation);
          throwIfAborted(options.signal);
        }
        if (state.sensitiveChoice === "cancel") {
          step.status = "failed";
          emitSteps();
          throw new LibraryResearchCancelledError();
        }
        if (state.sensitiveChoice === "redact") {
          read = applyServerRedactedLibraryRead(read);
        }
      }
      const citationIndex = addCitation(
        state.citations,
        citationRead,
        args as LibraryReadArgs,
      );
      result = citationIndex == null ? read : { ...read, citationIndex };
    }

    const payload: Record<string, unknown> = { ok: true, result };
    if (tool === "library_search" && state.requireListAfterEmptySearch) {
      payload.requiredNextTool = "library_list";
      payload.instruction = "Search returned no results. Call library_list next.";
    }
    step.status = "completed";
    emitSteps();
    return {
      content: JSON.stringify(payload),
      ...(stopReason !== undefined
        ? {
            stopReason,
            stoppedMessage: "The empty-result limit was reached.",
          }
        : {}),
    };
  } catch (error) {
    // This step is ok:false, the same nature as the generic failure branch: marking it completed
    // would draw "this document was not read" as a green tick on the steps bar, and the user would
    // think the evidence is complete.
    step.status = "failed";
    emitSteps();
    throw error;
  }
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
function libraryFailureDisposition(error: unknown): ToolFailureDisposition {
  if (error instanceof LibraryResearchCancelledError) return { kind: "fatal" };
  if (isFatalLibraryToolError(error)) return { kind: "fatal" };
  if (isLibraryNotFoundError(error)) {
    // A missing document is not a source or network fault: it is only fed back and does not
    // count towards consecutive failures. Treating it as a degrade would turn the whole reply into
    // an error card once the model reads three deleted documents in a row.
    return {
      kind: "neutral",
      code: "library_not_found",
      message:
        "The requested Library document was not found. Do not invent its contents; use other evidence or say it was not found.",
    };
  }
  return {
    kind: "degrade",
    code: toolFailureCode(error),
    message:
      "The Library tool call failed. Do not invent its contents; use other evidence or say the source was unavailable.",
  };
}

/**
 * Maps errors thrown by the generic loop or a model leg to the library's own error type. A
 * `ToolLoopError` from a model leg keeps its provider attribution, and a `ToolCallRejection` for
 * exceeding the self-correction limit becomes `library_invalid_tool_call`.
 */
function toLibraryAgentError(error: unknown): unknown {
  if (error instanceof LibraryResearchCancelledError) return error;
  if (error instanceof LibraryAgentError) return error;
  if (isAbortError(error)) return error;
  if (error instanceof ToolCallRejection) {
    return new LibraryAgentError(error.message, "library_invalid_tool_call");
  }
  if (error instanceof ToolLoopError) {
    return new LibraryAgentError(
      error.message,
      error.code,
      error.source,
      error.toolCallRejectionContext,
      error.streamStarted,
    );
  }
  return error;
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

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
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
