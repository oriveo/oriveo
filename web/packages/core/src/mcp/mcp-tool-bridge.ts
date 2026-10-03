/**
 * Plugs remote MCP tools into the generic tool loop. Behaviour matches the iOS `McpToolBridge.swift`.
 *
 * This layer turns "the servers enabled for this conversation" into registry entries for the generic
 * loop: it assembles the usable tools, builds the model-facing names and the lookup table, runs the
 * confirmation gate, performs the call and feeds the result back. UI (confirmation dialog, step blocks)
 * does not live here: the confirmation gate is an injectable interface and step changes are handed out
 * through a callback. Pure logic, testable under Node.
 */

import type { ProxyToolCall, ProxyToolDefinition } from '../providers/request-builders/runtime';
import {
  ToolCallRejection,
  effectiveToolLoopMaxSteps,
  type ToolExecutionContext,
  type ToolExecutionOutcome,
  type ToolFailureDisposition,
  type ToolLoopLimits,
  type ToolLoopPrompts,
  type ToolRegistryEntry,
} from '../tools/tool-loop-contracts';
import { McpAuthorizerError } from './mcp-auth';
import { outboundToolSnapshots } from './mcp-catalog';
import { McpClient, McpClientError, type McpToolCallResult } from './mcp-client';
import { isJsonObject, parseJsonLimited } from './mcp-json';
import { MCP_SAFETY_PROMPT, argsSummary, canonicalJsonString, outboundToolName } from './mcp-pure';
import { tryParseUrl } from './mcp-transport';
import {
  defaultPermissionFor,
  effectiveMaxSteps,
  type JsonObject,
  type JsonValue,
  type McpConnectionStatus,
  type McpErrorCode,
  type McpRuntimeConfig,
  type McpServerRecord,
  type McpToolPermission,
  type McpToolSnapshot,
} from './mcp-types';

// ── Confirmation gate ────────────────────────────────────────────────────

/** What the user picked in the confirmation dialog (the closed `choice` set of the `mcp_confirm_choice` event). */
export type McpConfirmationChoice =
  /** Allow once. */
  | 'once'
  /** Allow for the rest of this conversation (same tool on the same server only, kept in memory only). */
  | 'conversation'
  /** Deny: no `tools/call` is sent and `user_denied` is fed back. */
  | 'deny';

/**
 * What the confirmation dialog shows. The arguments are the raw top-level object the model produced
 * (keys verbatim); the dialog itself takes the first 4 and clamps them to two lines.
 */
export interface McpConfirmationRequest {
  conversationId: string;
  serverId: string;
  serverName: string;
  /** Host name of the server URL (display only). */
  serverHost: string;
  toolName: string;
  toolTitle: string;
  arguments: JsonObject;
  inputSchema: JsonValue;
  /**
   * The tool did not declare itself read-only (anything undeclared is treated as modifying data). The
   * dialog uses this to decide whether to warn that the tool may change the user's content.
   */
  changesData: boolean;
}

/**
 * Confirmation gate: a suspension point inside the loop; time spent waiting does not count towards the
 * call timeout. Several tools needing confirmation in one leg are executed serially by the loop, so they
 * are naturally asked one at a time, in proposal order. When the user presses stop (`signal` aborts) an
 * implementation should end the wait promptly - whatever it returns is fine, because the executor checks
 * for cancellation first once the gate returns.
 */
export interface McpConfirmationGate {
  requestConfirmation(request: McpConfirmationRequest, signal: AbortSignal): Promise<McpConfirmationChoice>;
}

/** The gate for when there is no UI to ask: always deny (fail closed). */
export const denyingMcpConfirmationGate: McpConfirmationGate = {
  requestConfirmation: async () => 'deny',
};

// ── Authorization expired mid-run ────────────────────────────────────────

/** What the loop hands to the UI when a step hits "sign in again". */
export interface McpReauthorizationRequest {
  conversationId: string;
  serverId: string;
  serverName: string;
  /** The step that is waiting here (a `toolSteps` id): the UI hangs its two buttons under that row. */
  stepId: string;
}

/** `reauthorized`: the user signed in again, resume from this step; `skip`: skip it (feeds back `auth_skipped`). */
export type McpReauthorizationChoice = 'reauthorized' | 'skip';

/**
 * Reauthorization gate: the loop parks on this step until the user signs in again or skips; the wait
 * does not count towards the call timeout. Signing in again (opening a browser) is a UI flow and is not
 * done inside the loop. Without a gate there is no pause and the step simply degrades to `needs_auth`.
 */
export interface McpReauthorizationGate {
  requestReauthorization(request: McpReauthorizationRequest, signal: AbortSignal): Promise<McpReauthorizationChoice>;
}

/** "Allow for this conversation": remembered per conversation + server + original tool name, in memory only, gone on page reload. */
export class McpConversationGrants {
  private readonly granted = new Set<string>();

  private static key(conversationId: string, serverId: string, toolName: string): string {
    return JSON.stringify([conversationId, serverId, toolName]);
  }

  grant(conversationId: string, serverId: string, toolName: string): void {
    this.granted.add(McpConversationGrants.key(conversationId, serverId, toolName));
  }

  isGranted(conversationId: string, serverId: string, toolName: string): boolean {
    return this.granted.has(McpConversationGrants.key(conversationId, serverId, toolName));
  }

  /**
   * Revokes a tool's "always allow" in every conversation: the user changed its permission, or its
   * description / parameters / title changed (what the user allowed back then is not the tool as it is now).
   */
  revokeTool(serverId: string, toolName: string): void {
    for (const key of [...this.granted]) {
      const [, grantedServer, grantedTool] = JSON.parse(key) as string[];
      if (grantedServer === serverId && grantedTool === toolName) this.granted.delete(key);
    }
  }

  /** Clears the related grants when a server is removed or the profile partition changes. */
  revokeServer(serverId: string): void {
    for (const key of [...this.granted]) if ((JSON.parse(key) as string[])[1] === serverId) this.granted.delete(key);
  }

  revokeAll(): void {
    this.granted.clear();
  }
}

// ── Assembly ─────────────────────────────────────────────────────────────

/** One enabled server's input for this request (read from local storage by the app layer, in enable order). */
export interface McpBridgeServerInput {
  record: McpServerRecord;
  connectionStatus: McpConnectionStatus | null;
  snapshots: readonly McpToolSnapshot[];
  permissions: Readonly<Record<string, McpToolPermission>>;
}

/** One lookup-table entry: model-facing name → server and original tool name. */
export interface McpToolBinding {
  outboundName: string;
  serverId: string;
  toolName: string;
}

/** One MCP tool usable in this request. */
export interface McpPlannedTool {
  binding: McpToolBinding;
  server: McpServerRecord;
  /** URL requests are sent to (on the web this is simply the full URL from the record). */
  endpoint: string;
  snapshot: McpToolSnapshot;
  /** Only ever `auto` or `ask`: `off` is already excluded during assembly. */
  permission: Exclude<McpToolPermission, 'off'>;
  definition: ProxyToolDefinition;
}

/** The MCP tools and lookup table for this request. Empty = the request carries no MCP tools. */
export interface McpToolPlan {
  tools: McpPlannedTool[];
  /** More usable tools than `maxToolsPerRequest`; the tail was cut in server enable order. */
  truncated: boolean;
  /** Lookup table. Names coming back from the model are resolved here only; a miss means "not in the registry". */
  nameTable: ReadonlyMap<string, McpToolBinding>;
}

export const EMPTY_MCP_TOOL_PLAN: McpToolPlan = Object.freeze({ tools: [], truncated: false, nameTable: new Map() });

/**
 * Assembles the tools usable right now: enabled servers (in enable order) ∩ usable connection, minus
 * tools that are set to "off", quarantined or oversized; truncated above `maxToolsPerRequest`. A server
 * that needs a new sign-in (`needsAuth`) is excluded as a whole. Empty when `enabled` is false (master
 * switch off).
 */
export function planMcpTools(servers: readonly McpBridgeServerInput[], runtimeConfig: McpRuntimeConfig): McpToolPlan {
  if (!runtimeConfig.enabled || servers.length === 0) return EMPTY_MCP_TOOL_PLAN;
  const tools: McpPlannedTool[] = [];
  const nameTable = new Map<string, McpToolBinding>();
  let truncated = false;
  serverLoop: for (const server of servers) {
    if (server.connectionStatus === 'needsAuth') continue;
    // Only https URLs are accepted; stored records already passed validation, this guards the invariant.
    if (tryParseUrl(server.record.url)?.protocol !== 'https:') continue;
    const outbound = outboundToolSnapshots(server.snapshots, server.permissions);
    const names = outbound.map((snapshot) => snapshot.toolName);
    for (const snapshot of outbound) {
      const name = outboundToolName({
        slug: server.record.slug,
        serverId: server.record.id,
        toolName: snapshot.toolName,
        collidesWith: names.filter((other) => other !== snapshot.toolName),
      }).name;
      // Slugs are unique across servers so this should not collide; if it ever does, keep only the first
      // enabled one - a single name must never point at two targets.
      if (nameTable.has(name)) continue;
      if (tools.length >= runtimeConfig.maxToolsPerRequest) {
        truncated = true;
        break serverLoop;
      }
      const stored = server.permissions[snapshot.toolName] ?? defaultPermissionFor(snapshot.readOnly);
      const binding: McpToolBinding = { outboundName: name, serverId: server.record.id, toolName: snapshot.toolName };
      nameTable.set(name, binding);
      tools.push({
        binding,
        server: server.record,
        endpoint: server.record.url,
        snapshot,
        permission: stored === 'auto' ? 'auto' : 'ask',
        definition: {
          type: 'function',
          function: {
            name,
            // The description is sent verbatim, with nothing of ours prepended.
            description: snapshot.description ?? '',
            parameters: isJsonObject(snapshot.inputSchema) ? (snapshot.inputSchema as Record<string, unknown>) : { type: 'object' },
          },
        },
      });
    }
  }
  return { tools, truncated, nameTable };
}

// ── Revalidation before execution ────────────────────────────────────────
//
// Assembly happens the moment the answer starts, and one answer can run for a long time: waiting for
// the model, waiting for the user to confirm, parked on "authorization expired" until a new sign-in.
// Meanwhile the user (or another tab) may have removed the server, turned the conversation switch off,
// set the tool to "off", or the server may have changed its tool definitions during the new sign-in. So
// right before `tools/call` is actually sent, everything is checked again against the local state **at
// that moment** instead of relying on the snapshot taken at assembly.

/** Outcome of the revalidation. */
export type McpToolRevalidation =
  /** Still usable; `permission` is the one in effect now (it may have changed from auto-run to ask-every-time). */
  | { kind: 'usable'; permission: Exclude<McpToolPermission, 'off'>; dropConnection: boolean }
  /** No longer usable: no request is sent and `tool_unavailable` is fed back. */
  | { kind: 'unavailable'; dropConnection: boolean };

/**
 * Compares the tool as assembled with the local state right now. `current` is `null` when the server is
 * gone or this conversation has turned it off.
 *
 * Unusable: server gone / switch off / URL changed; the tool was removed by the server, quarantined or
 * oversized; content hash or display title differs from assembly time (the model proposed against the
 * old definition); permission is "off".
 * `dropConnection`: when the server is gone, its URL changed or it needs a new sign-in, the connection
 * cached for this answer (together with the token it carries) must not be reused.
 */
export function revalidatePlannedTool(tool: McpPlannedTool, current: McpBridgeServerInput | null): McpToolRevalidation {
  if (!current || current.record.id !== tool.server.id || current.record.url !== tool.endpoint) {
    return { kind: 'unavailable', dropConnection: true };
  }
  const dropConnection = current.connectionStatus === 'needsAuth';
  const snapshot = current.snapshots.find((item) => item.toolName === tool.snapshot.toolName);
  if (
    !snapshot ||
    snapshot.pendingReview ||
    snapshot.oversized ||
    snapshot.contentHash !== tool.snapshot.contentHash ||
    snapshot.title !== tool.snapshot.title
  ) {
    return { kind: 'unavailable', dropConnection };
  }
  const permission = current.permissions[snapshot.toolName] ?? defaultPermissionFor(snapshot.readOnly);
  if (permission === 'off') return { kind: 'unavailable', dropConnection };
  return { kind: 'usable', permission: permission === 'auto' ? 'auto' : 'ask', dropConnection };
}

// ── Loop parameters ──────────────────────────────────────────────────────

/** Error code for skipped calls: neutral, deliberately not the library's `research_stopped`. */
export const MCP_LOOP_STOPPED_ERROR_CODE = 'tool_loop_stopped';

/** Fixed sentences the loop feeds back to the model: neutral wording, without the library's "cite sources as [n]". Identical to iOS word for word. */
export const MCP_LOOP_PROMPTS: ToolLoopPrompts = {
  stepLimitReached:
    'The tool call limit was reached. Answer now from the tool results you already have. Do not call another tool.',
  tokenBudgetReached:
    'The token budget for tool use was reached. Answer now from the tool results you already have. Do not call another tool.',
  stoppedByStepLimit: 'The tool call limit was reached.',
  stoppedByTokenBudget: 'The token budget for tool use was reached.',
};

/**
 * Loop limits when MCP tools are present. The consecutive-failure breaker is turned off: an error from
 * one third-party server should not blow up the whole answer; the only whole-run abort is the user
 * pressing stop. The step count is still bounded by `maxSteps`, so errors are not fed back forever.
 */
export function mcpLoopLimits(runtimeConfig: McpRuntimeConfig): ToolLoopLimits {
  return {
    maxSteps: effectiveToolLoopMaxSteps(effectiveMaxSteps(runtimeConfig)),
    maxConsecutiveToolFailures: Number.POSITIVE_INFINITY,
  };
}

/** Fixed text appended to the system prompt when MCP tools are enabled (fixture `safety-prompt.txt`). */
export function mcpSystemPrompt(base: string | null | undefined): string {
  const trimmed = (base ?? '').trim();
  return trimmed ? `${trimmed}\n\n${MCP_SAFETY_PROMPT}` : MCP_SAFETY_PROMPT;
}

// ── Execution ────────────────────────────────────────────────────────────

/**
 * A call that did not succeed. `code` comes from the closed error-code set; only that code and one fixed
 * sentence are fed back to the model, never the server's own text.
 */
export class McpToolFailure extends Error {
  readonly code: McpErrorCode;
  constructor(code: McpErrorCode) {
    super(`MCP tool call failed: ${code}`);
    this.name = 'McpToolFailure';
    this.code = code;
  }
}

export type McpToolStepStatus = 'running' | 'done' | 'failed' | 'denied' | 'needsAuth' | 'interrupted';

/** Per-step payload: the raw arguments and the beginning of the result. Stored apart from the message, which only keeps the summary. */
export interface McpToolStepPayload {
  /** Raw arguments from the model (canonical JSON). The storage layer truncates to 16 KB. */
  arguments: string | null;
  /** Beginning of the result (the storage layer truncates to 2 KB); on failure, the server's error text truncated to 200 characters. */
  resultPrefix: string | null;
}

export const MCP_STEP_FAILURE_TEXT_MAX_LENGTH = 200;

/**
 * One state change of a step (the fields of a `toolSteps` entry). `payload`, `permission` and `readOnly`
 * do not go into the message: the payload is stored on this device only, the other two exist for
 * analytics only.
 */
export interface McpToolStepUpdate {
  id: string;
  serverId: string;
  serverName: string;
  toolName: string;
  title: string;
  argsSummary: string;
  status: McpToolStepStatus;
  errorCode: McpErrorCode | null;
  step: number;
  durationMs: number | null;
  /** The permission in effect for this call and the tool's read-only declaration: two closed-set fields of the `mcp_tool_call` event. */
  permission: 'auto' | 'ask';
  readOnly: boolean;
  /**
   * The step is parked in `needsAuth` waiting for the user to sign in again or skip; it is not terminal
   * yet: a `running` (resumed after the new sign-in) or a `needsAuth` carrying `auth_skipped` (skipped)
   * follows. Analytics are recorded on the terminal state only.
   */
  awaitingUser: boolean;
  /** Stored only on the device that ran the step: raw arguments arrive with the first callback, the result / failure text with the terminal state. */
  payload: McpToolStepPayload | null;
}

export interface McpToolExecutorOptions {
  conversationId: string;
  runtimeConfig: McpRuntimeConfig;
  gate: McpConfirmationGate;
  grants: McpConversationGrants;
  /** Fetches a usable token for the server before a call (refresh only, no new sign-in - that needs a browser and is a UI flow). */
  tokenProvider: (serverId: string) => Promise<string | null>;
  makeClient: (endpoint: string) => McpClient;
  /** Pauses for the user when authorization expires mid-run. Without it there is no pause. */
  reauthorizationGate?: McpReauthorizationGate;
  /**
   * Revalidation before execution: returns the server's local state right now (`null` when the server is
   * gone or this conversation has turned it off). Asked before every `tools/call`, after a confirmation
   * wait and before resuming after a new sign-in. Production must provide it; without it the snapshot
   * taken at assembly is used.
   */
  revalidate?: (serverId: string, toolName: string) => Promise<McpBridgeServerInput | null> | McpBridgeServerInput | null;
  onStep?: (update: McpToolStepUpdate) => void | Promise<void>;
  now?: () => number;
}

function abortError(): DOMException {
  return new DOMException('Aborted', 'AbortError');
}

/** The MCP executor for one answer: owns this run's clients (one connection per server), the confirmation gate and the in-memory grants. */
export class McpToolExecutor {
  private readonly options: McpToolExecutorOptions;
  private readonly clients = new Map<string, McpClient>();
  private readonly now: () => number;

  constructor(options: McpToolExecutorOptions) {
    this.options = options;
    this.now = options.now ?? (() => Date.now());
  }

  async execute(tool: McpPlannedTool, call: ProxyToolCall, context: ToolExecutionContext): Promise<ToolExecutionOutcome> {
    const { conversationId, gate, grants } = this.options;
    const args = validatedMcpArguments(call.function.arguments, tool.snapshot.inputSchema);
    const step: McpToolStepUpdate = {
      id: `${context.stepNumber}:${call.id}`,
      serverId: tool.server.id,
      serverName: tool.server.name,
      toolName: tool.snapshot.toolName,
      title: tool.snapshot.title,
      argsSummary: argsSummary(tool.snapshot.inputSchema, args),
      status: 'running',
      errorCode: null,
      step: context.stepNumber,
      durationMs: null,
      permission: tool.permission,
      readOnly: tool.snapshot.readOnly,
      awaitingUser: false,
      payload: { arguments: canonicalJsonString(args), resultPrefix: null },
    };
    const emit = async () => {
      await this.options.onStep?.({ ...step, payload: step.payload ? { ...step.payload } : null });
    };

    // The step is `running` from the moment it is proposed: the step block and the activity line stay
    // visible while waiting for confirmation (that is waiting for a person, not silence).
    // The raw arguments are handed out with this first callback only.
    await emit();
    step.payload = null;

    // Once the user allowed "this call" they are not asked a second time; the local state is still
    // revalidated before every request that is actually sent.
    let approved = false;
    /** Revalidates and, if needed, runs the confirmation gate. Non-null = the step ends here (the user denied) and is fed back as is. */
    const admit = async (): Promise<ToolExecutionOutcome | null> => {
      for (;;) {
        const verdict = await this.revalidated(tool);
        if (context.signal.aborted) {
          step.awaitingUser = false;
          step.status = 'interrupted';
          step.errorCode = 'cancelled';
          await emit();
          throw abortError();
        }
        if (verdict.dropConnection) this.clients.delete(tool.server.id);
        if (verdict.kind === 'unavailable') {
          // No request is sent. The model only gets the closed-set code; retrying against a definition
          // that no longer exists or has changed would be pointless.
          step.awaitingUser = false;
          step.status = 'failed';
          step.errorCode = 'tool_unavailable';
          await emit();
          throw new McpToolFailure('tool_unavailable');
        }
        step.permission = verdict.permission;
        // "Ask every time" never sends tools/call without the user allowing it.
        if (verdict.permission === 'auto' || approved || grants.isGranted(conversationId, tool.server.id, tool.snapshot.toolName)) {
          return null;
        }
        let choice: McpConfirmationChoice;
        try {
          choice = await gate.requestConfirmation(
            {
              conversationId,
              serverId: tool.server.id,
              serverName: tool.server.name,
              serverHost: tryParseUrl(tool.endpoint)?.hostname ?? '',
              toolName: tool.snapshot.toolName,
              toolTitle: tool.snapshot.title,
              arguments: args,
              inputSchema: tool.snapshot.inputSchema,
              changesData: !tool.snapshot.readOnly,
            },
            context.signal,
          );
          if (context.signal.aborted) throw abortError();
        } catch (error) {
          // The user pressed stop while waiting for confirmation (or the gate itself failed): the step
          // did not run and is recorded as interrupted.
          step.status = 'interrupted';
          step.errorCode = context.signal.aborted ? 'cancelled' : 'interrupted';
          await emit();
          throw context.signal.aborted ? abortError() : error;
        }
        if (choice === 'conversation') {
          grants.grant(conversationId, tool.server.id, tool.snapshot.toolName);
        } else if (choice !== 'once') {
          // Any unrecognized return value is treated as a denial (fail closed).
          step.status = 'denied';
          step.errorCode = 'user_denied';
          await emit();
          // A denial is not a server failure: it is fed back as a normal result and does not advance
          // the consecutive-failure count.
          return {
            content: mcpErrorContent(
              'user_denied',
              'The user declined this tool call. Do not call it again for this request; continue without it.',
            ),
          };
        }
        approved = true;
        // The dialog may have been open for a long time: the user allowed the tool they saw, so check
        // once more that it still exists and still has that definition.
      }
    };

    const refused = await admit();
    if (refused) return refused;

    // When authorization expires the loop parks on this step waiting for the user: after a new sign-in
    // it resumes from this step, a skip feeds back `auth_skipped`. A 401 means this tools/call was not
    // executed, so sending it again after the new sign-in does not run anything twice.
    for (;;) {
      try {
        return await this.callOnce(tool, args, step, emit, context);
      } catch (error) {
        const reauthGate = this.options.reauthorizationGate;
        if (!(error instanceof McpToolFailure) || error.code !== 'needs_auth' || !reauthGate) throw error;
        let choice: McpReauthorizationChoice;
        try {
          choice = await reauthGate.requestReauthorization(
            { conversationId, serverId: tool.server.id, serverName: tool.server.name, stepId: step.id },
            context.signal,
          );
        } catch {
          choice = 'skip';
        }
        if (context.signal.aborted) {
          step.awaitingUser = false;
          step.status = 'interrupted';
          step.errorCode = 'cancelled';
          await emit();
          throw abortError();
        }
        step.awaitingUser = false;
        if (choice !== 'reauthorized') {
          step.errorCode = 'auth_skipped';
          await emit();
          throw new McpToolFailure('auth_skipped');
        }
        // The old connection carries the expired token: drop it, next time fetch a token and reconnect.
        this.clients.delete(tool.server.id);
        // During the new sign-in the server may have changed its tool definitions (quarantine) and the
        // user may have changed the permission or removed the server along the way: resuming is not
        // "send the previous call again", it has to go through admission again with the current state.
        const refusedAfterReauth = await admit();
        if (refusedAfterReauth) return refusedAfterReauth;
        step.status = 'running';
        step.errorCode = null;
        step.durationMs = null;
        await emit();
      }
    }
  }

  /**
   * Revalidates this tool against the local state right now. Without an injected revalidation the
   * assembly-time verdict stands. State that cannot be read counts as unavailable (fail closed).
   */
  private async revalidated(tool: McpPlannedTool): Promise<McpToolRevalidation> {
    const revalidate = this.options.revalidate;
    if (!revalidate) return { kind: 'usable', permission: tool.permission, dropConnection: false };
    let current: McpBridgeServerInput | null;
    try {
      current = await revalidate(tool.server.id, tool.snapshot.toolName);
    } catch {
      return { kind: 'unavailable', dropConnection: true };
    }
    return revalidatePlannedTool(tool, current);
  }

  /** Connects and calls once; the terminal state (done / failed / needsAuth / interrupted) is emitted here. */
  private async callOnce(
    tool: McpPlannedTool,
    args: JsonObject,
    step: McpToolStepUpdate,
    emit: () => Promise<void>,
    context: ToolExecutionContext,
  ): Promise<ToolExecutionOutcome> {
    const startedAt = this.now();
    const elapsed = () => Math.max(0, Math.round(this.now() - startedAt));
    try {
      const client = await this.connectedClient(tool, context.signal);
      let result: McpToolCallResult;
      try {
        result = await client.callTool(tool.snapshot.toolName, args, { signal: context.signal });
      } catch (error) {
        throw this.failureFor(error, context.signal);
      }
      step.durationMs = elapsed();
      if (result.errorCode === 'tool_error' || result.errorCode === 'needs_input_unsupported') {
        // The failure text goes into the local per-step payload only, never into `toolSteps` and never
        // back to the model.
        const text = Array.from(result.text).slice(0, MCP_STEP_FAILURE_TEXT_MAX_LENGTH).join('');
        step.payload = text ? { arguments: null, resultPrefix: text } : null;
        throw new McpToolFailure(result.errorCode);
      }
      step.status = 'done';
      step.errorCode = result.errorCode;
      step.payload = result.text ? { arguments: null, resultPrefix: result.text } : null;
      await emit();
      return { content: JSON.stringify({ ok: true, result: result.text || 'The tool returned no content.' }) };
    } catch (error) {
      step.durationMs = step.durationMs ?? elapsed();
      if (error instanceof McpToolFailure) {
        step.status = error.code === 'needs_auth' ? 'needsAuth' : 'failed';
        step.errorCode = error.code;
        step.awaitingUser = error.code === 'needs_auth' && Boolean(this.options.reauthorizationGate);
      } else {
        // The user pressed stop (or some other unexpected error): the step did not finish.
        step.status = 'interrupted';
        step.errorCode = context.signal.aborted ? 'cancelled' : 'interrupted';
      }
      await emit();
      step.payload = null;
      throw error;
    }
  }

  /** One connection per server per run; the token comes from the credential store. */
  private async connectedClient(tool: McpPlannedTool, signal: AbortSignal): Promise<McpClient> {
    const existing = this.clients.get(tool.server.id);
    if (existing) return existing;
    let token: string | null;
    try {
      token = await this.options.tokenProvider(tool.server.id);
    } catch (error) {
      if (signal.aborted) throw abortError();
      throw new McpToolFailure(error instanceof McpAuthorizerError && !error.isTransient ? 'needs_auth' : 'unreachable');
    }
    if (signal.aborted) throw abortError();
    const client = this.options.makeClient(tool.endpoint);
    const outcome = await client.connect({ bearerToken: token, signal });
    if (signal.aborted) throw abortError();
    switch (outcome.kind) {
      case 'connected':
        this.clients.set(tool.server.id, client);
        return client;
      case 'needsAuth':
        throw new McpToolFailure('needs_auth');
      case 'unreachable':
        throw new McpToolFailure('unreachable');
      case 'notMcp':
        throw new McpToolFailure('server_error');
      case 'failed':
        throw this.failureFor(outcome.error, signal);
    }
  }

  /** Cancellation is turned back into an AbortError so the loop winds the whole run down as "user pressed stop" instead of feeding it back as a failure. */
  private failureFor(error: unknown, signal: AbortSignal): Error {
    if (signal.aborted) return abortError();
    if (error instanceof McpClientError) return new McpToolFailure(error.code);
    if (error instanceof Error && error.name === 'AbortError') return error;
    return new McpToolFailure('server_error');
  }
}

/** Arguments must be a JSON object carrying every `required` key; otherwise the loop counts it as a model self-correction. */
export function validatedMcpArguments(raw: string, schema: JsonValue): JsonObject {
  const trimmed = raw.trim();
  const parsed = trimmed ? parseJsonLimited(trimmed) : {};
  if (!isJsonObject(parsed)) {
    throw new ToolCallRejection('invalid_arguments', 'Tool arguments must be a JSON object.');
  }
  const required = isJsonObject(schema) && Array.isArray(schema.required)
    ? schema.required.filter((item): item is string => typeof item === 'string')
    : [];
  const missing = required.filter((key) => !Object.hasOwn(parsed, key));
  if (missing.length > 0) {
    throw new ToolCallRejection('missing_required_arguments', `Missing required arguments: ${missing.join(', ')}.`);
  }
  return parsed;
}

export function mcpErrorContent(code: string, message: string): string {
  return JSON.stringify({ ok: false, error: { code, message } });
}

/** Always `degrade`; only the user pressing stop aborts the whole run (the loop recognizes AbortError itself). */
export function mcpFailureDisposition(error: unknown): ToolFailureDisposition {
  if (error instanceof Error && error.name === 'AbortError') return { kind: 'fatal' };
  const code: McpErrorCode = error instanceof McpToolFailure ? error.code : 'server_error';
  return {
    kind: 'degrade',
    code,
    message: 'The tool call did not succeed. Do not invent its result; continue with what you have.',
  };
}

/** Registry entries (registration order = order sent to the model). One MCP tool = one entry. */
export function createMcpToolEntries(plan: McpToolPlan, executor: McpToolExecutor): ToolRegistryEntry[] {
  return plan.tools.map((tool) => ({
    name: tool.binding.outboundName,
    scope: 'mcp' as const,
    definition: tool.definition,
    execute: (call, context) => executor.execute(tool, call, context),
    failureDisposition: mcpFailureDisposition,
  }));
}
