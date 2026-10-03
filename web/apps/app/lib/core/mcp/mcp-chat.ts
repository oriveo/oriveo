/**
 * The application layer that plugs remote MCP into the chat send path.
 *
 * The send path asks this module three things only: which MCP tools this request carries
 * (`prepareMcpSend`), how to turn them into registry entries for the generic tool loop
 * (`createMcpSendSession`), and, when a new conversation gets its real id, to move over the servers
 * enabled in the draft (`adoptMcpDraftServers`). Assembly, naming, confirmation, invocation and
 * feeding results back all live in the bridge in `@oriveo/core/mcp`; this module only wires up
 * local storage, credentials, the confirmation gate and the steps on the message.
 */

import type { AIModel, McpToolStep, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';
import type { ToolRegistryEntry } from '@oriveo/core/tools/tool-loop-contracts';
import {
  EMPTY_MCP_TOOL_PLAN,
  McpToolExecutor,
  createMcpToolEntries,
  planMcpTools,
  type McpBridgeServerInput,
  type McpRuntimeConfig,
  type McpToolPlan,
  type McpToolStepUpdate,
} from '@oriveo/core/mcp/index';
import { effectiveCapabilityTransport, resolveModelCapabilityEvidence } from '../chat/capability-evidence';
import { currentMcpConfirmationGate, currentMcpReauthorizationGate, mcpConversationGrants } from './mcp-confirmation';
import { loadMcpLocalState, saveMcpStepPayload } from './mcp-idb';
import { createMcpClient, currentMcpRuntimeConfig, getMcpAuthorizer, mcpDraftScope, useMcpStore, type McpStoreState } from './mcp-store';
import { reportMcpToolCall } from './mcp-telemetry';
import { mergeMcpToolStep } from './mcp-tool-steps';

/** The four wire protocols that can carry client-side tools (the same set as the library agent, handled by the same wire adapters). */
const TOOL_ADAPTER_TRANSPORTS = new Set(['openai_chat', 'openai_responses', 'anthropic_messages', 'gemini_generate_content']);

/**
 * Whether this connection and this model can carry MCP tools. No provider kind is special-cased:
 * the test is the same as the library agent's, namely that the effective wire protocol is one of
 * the four and the central capability evidence does not explicitly say tools are unsupported
 * (unknown counts as sendable; when the upstream explicitly rejects tools the send path retries
 * once without them and remembers).
 */
export function connectionSupportsMcpTools(provider: Provider | undefined, model: AIModel | undefined, streamOptions?: StreamOptions): boolean {
  if (!provider || !model) return false;
  // Image generation models use the image endpoint, not the chat endpoint, and cannot carry client-side tools.
  if (model.capabilities.includes('imageGeneration') && Boolean(model.imageGenProfile)) return false;
  const transport = effectiveCapabilityTransport(provider, model, undefined, streamOptions);
  if (!TOOL_ADAPTER_TRANSPORTS.has(transport)) return false;
  return resolveModelCapabilityEvidence({ key: 'tool_call', provider, model, effectiveTransport: transport, streamOptions }).support !== 'unsupported';
}

/** The slice of local state shared by assembly and revalidation (both the in-memory projection and a direct database read have this shape). */
type McpScopeState = Pick<McpStoreState, 'servers' | 'snapshots' | 'permissions' | 'connections' | 'conversationServers'>;

/** Servers enabled for this conversation (or draft scope), in the order they were enabled, with their tool snapshots and permissions. */
export function mcpServerInputsForScope(scope: string | undefined, state: McpScopeState = useMcpStore.getState()): McpBridgeServerInput[] {
  if (!scope) return [];
  const enabled = state.conversationServers[scope] ?? [];
  const inputs: McpBridgeServerInput[] = [];
  for (const serverId of enabled) {
    const record = state.servers.find((server) => server.id === serverId);
    if (!record) continue;
    inputs.push({
      record,
      connectionStatus: state.connections[serverId]?.status ?? null,
      // Sorted by tool name: that is the order the local database returns, and it stays the same
      // right after a catalog refresh (when memory holds the server's order), so the tool order
      // sent to the model and the result of over-limit truncation do not change across reloads.
      snapshots: [...(state.snapshots[serverId] ?? [])].sort((a, b) => (a.toolName < b.toolName ? -1 : a.toolName > b.toolName ? 1 : 0)),
      permissions: state.permissions[serverId] ?? {},
    });
  }
  return inputs;
}

export interface McpSendScope {
  /** Id of an existing conversation; empty when a new conversation sends its first message. */
  conversationId?: string;
  /** Draft session id of a new conversation (the same one the generation-parameter draft uses). */
  draftSessionId?: string;
}

function resolveScope(scope: McpSendScope): string | undefined {
  if (scope.conversationId) return scope.conversationId;
  return scope.draftSessionId ? mcpDraftScope(scope.draftSessionId) : undefined;
}

/**
 * The MCP tools available to this send. The plan is empty when the conversation has no server
 * enabled, the connection cannot carry tools, the master switch is off, or the store has not
 * hydrated yet; an empty plan takes the ordinary send path with no MCP tools in the request. A
 * configuration that cannot be read must not fail the whole message.
 */
export function prepareMcpSend(input: McpSendScope & { provider: Provider; model: AIModel; runtimeConfig?: McpRuntimeConfig }): McpToolPlan {
  try {
    const state = useMcpStore.getState();
    if (!state.hydrated) return EMPTY_MCP_TOOL_PLAN;
    const servers = mcpServerInputsForScope(resolveScope(input));
    if (servers.length === 0) return EMPTY_MCP_TOOL_PLAN;
    if (!connectionSupportsMcpTools(input.provider, input.model)) return EMPTY_MCP_TOOL_PLAN;
    return planMcpTools(servers, input.runtimeConfig ?? currentMcpRuntimeConfig());
  } catch {
    return EMPTY_MCP_TOOL_PLAN;
  }
}

/** A new conversation got its real id: move over the servers enabled under the draft scope. A failure does not affect sending. */
export function adoptMcpDraftServers(draftSessionId: string | undefined, conversationId: string): void {
  if (!draftSessionId) return;
  const store = useMcpStore.getState();
  if (!store.hydrated) return;
  const adoption = store.adoptDraftServers(mcpDraftScope(draftSessionId), conversationId).catch(() => {});
  pendingAdoptions.add(adoption);
  void adoption.finally(() => pendingAdoptions.delete(adoption));
}

/** Draft switch moves not yet persisted: memory already uses the real id while the database still has the draft scope. Pre-execution revalidation waits for these before reading the database. */
const pendingAdoptions = new Set<Promise<void>>();

/**
 * The "state right now" used for pre-execution revalidation: this server's current record, tool
 * snapshots, permissions and connection state in this conversation. It is `null` when the server
 * is gone, the conversation has turned it off, or the active profile partition is no longer the
 * one that started the reply.
 *
 * This reads the local database directly instead of the in-memory projection: when another tab has
 * just removed a server or changed a permission, this page's projection only updates once the
 * broadcast arrives (and never does in a browser without BroadcastChannel), whereas the database is
 * the single copy shared by all tabs. If the database cannot be read it falls back to the in-memory
 * projection, which still reflects every change this page made itself.
 */
export async function currentMcpServerInput(uid: string, conversationId: string, serverId: string): Promise<McpBridgeServerInput | null> {
  const memory = useMcpStore.getState();
  if (!memory.hydrated || memory.uid !== uid) return null;
  await Promise.allSettled([...pendingAdoptions]);
  let state: McpScopeState = useMcpStore.getState();
  try {
    const local = await loadMcpLocalState(uid);
    // A half-finished addition another tab has not confirmed yet does not count (same rule as the in-memory projection).
    state = { ...local, servers: local.servers.filter((server) => !server.pendingAdd), conversationServers: local.switches };
  } catch {
    // Fall back to the in-memory projection.
  }
  if (useMcpStore.getState().uid !== uid) return null;
  return mcpServerInputsForScope(conversationId, state).find((server) => server.record.id === serverId) ?? null;
}

export interface McpSendSession {
  /** Entries registered with the generic tool loop (registration order is the order sent to the model). */
  entries: ToolRegistryEntry[];
  /** Step summaries of this reply so far. */
  steps(): McpToolStep[];
}

/**
 * The MCP execution session of one reply: executor, registry entries and step persistence.
 *
 * On every status change: the summary is merged into `steps` and handed to `onSteps` (the send path
 * writes it to the message's `toolSteps`); the raw arguments and the start of the result go into the
 * local per-step payload (never into the message); and when the server demands a new
 * sign-in its connection state becomes `needsAuth`, which makes the tools panel show "re-authorize"
 * and keeps its tools out of later sends. A step reaching a terminal state reports one
 * `mcp_tool_call` (closed-set fields only); pausing at "waiting for re-authorization" is not a
 * terminal state and reports nothing.
 */
export function createMcpSendSession(input: {
  uid: string;
  conversationId: string;
  messageId: string;
  plan: McpToolPlan;
  initialSteps?: readonly McpToolStep[];
  runtimeConfig?: McpRuntimeConfig;
  onSteps: (steps: McpToolStep[]) => void;
  /**
   * Activity status line: set to `mcp_tool` while a step is `running` and cleared as soon as that
   * step leaves `running`. The server name and tool title to display are read by the UI from the
   * message's `toolSteps`, not passed through here.
   */
  onActivity?: (activity: 'mcp_tool' | null) => void;
  /** A step reached a terminal state (done / failed / denied / needsAuth / interrupted). */
  onStepSettled?: (update: McpToolStepUpdate) => void;
}): McpSendSession {
  const runtimeConfig = input.runtimeConfig ?? currentMcpRuntimeConfig();
  let steps: McpToolStep[] = [...(input.initialSteps ?? [])];
  // The loop only refreshes tokens and never signs in again (signing in opens a browser and is a UI
  // flow). It shares one authorizer with the management page, so when both notice the token is
  // about to expire only one refresh happens.
  const authorizer = getMcpAuthorizer(input.uid);

  // The first callback has only arguments and the terminal one only the result: arguments are kept
  // in memory and written together with the result at the end, so the two writes never clobber each other.
  const argumentsByStep = new Map<string, string | null>();
  const onStep = (update: McpToolStepUpdate): void => {
    steps = mergeMcpToolStep(steps, update);
    input.onSteps([...steps]);
    if (update.payload) {
      if (update.payload.arguments !== null) argumentsByStep.set(update.id, update.payload.arguments);
      void saveMcpStepPayload(input.uid, {
        messageId: input.messageId,
        stepId: update.id,
        serverId: update.serverId,
        conversationId: input.conversationId,
        arguments: argumentsByStep.get(update.id) ?? null,
        resultPrefix: update.payload.resultPrefix,
      }).catch(() => {});
    }
    input.onActivity?.(update.status === 'running' ? 'mcp_tool' : null);
    if (update.status === 'running') {
      // Continuing after re-authorization: this server is usable again.
      if (reauthorizing.delete(update.serverId)) markServerConnected(update.serverId);
      return;
    }
    if (update.status === 'needsAuth') markServerNeedsAuth(update.serverId);
    // Pausing at "waiting for re-authorization" is not a terminal state yet: keep the arguments and
    // report telemetry only at the real terminal state.
    if (update.awaitingUser) {
      reauthorizing.add(update.serverId);
      return;
    }
    reauthorizing.delete(update.serverId);
    argumentsByStep.delete(update.id);
    reportMcpToolCall(update);
    input.onStepSettled?.(update);
  };
  const reauthorizing = new Set<string>();

  const executor = new McpToolExecutor({
    conversationId: input.conversationId,
    runtimeConfig,
    gate: { requestConfirmation: (request, signal) => currentMcpConfirmationGate().requestConfirmation(request, signal) },
    grants: mcpConversationGrants,
    tokenProvider: (serverId) => authorizer.validAccessToken(serverId, input.uid),
    makeClient: (endpoint) => createMcpClient(endpoint, runtimeConfig),
    // With the chat UI present, pause and wait for the user; without it (nobody can press
    // "re-authorize") do not pause and degrade straight to needs_auth.
    reauthorizationGate: currentMcpReauthorizationGate() ?? undefined,
    // Revalidate against the current local state before sending: a removed server, a switch turned
    // off, or a tool set to "do not use" or quarantined is no longer called.
    revalidate: (serverId) => currentMcpServerInput(input.uid, input.conversationId, serverId),
    onStep,
  });
  return { entries: createMcpToolEntries(input.plan, executor), steps: () => [...steps] };
}

function markServerConnected(serverId: string): void {
  const store = useMcpStore.getState();
  const current = store.connections[serverId];
  if (current?.status === 'connected') return;
  void store.saveConnectionState({
    serverId,
    status: 'connected',
    lastSuccessAt: Date.now(),
    negotiatedVersion: current?.negotiatedVersion ?? null,
    generation: current?.generation ?? null,
    sessionId: null,
  }).catch(() => {});
}

function markServerNeedsAuth(serverId: string): void {
  const store = useMcpStore.getState();
  const current = store.connections[serverId];
  if (current?.status === 'needsAuth') return;
  void store.saveConnectionState({
    serverId,
    status: 'needsAuth',
    lastSuccessAt: current?.lastSuccessAt ?? null,
    negotiatedVersion: current?.negotiatedVersion ?? null,
    generation: current?.generation ?? null,
    sessionId: null,
  }).catch(() => {});
}
