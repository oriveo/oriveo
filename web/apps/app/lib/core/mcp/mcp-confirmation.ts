/**
 * Application-layer wiring of the confirmation gate.
 *
 * The send path only uses `currentMcpConfirmationGate()`. With no UI to ask, the gate denies
 * everything (fail closed). Only after the global prompt host (`McpGlobalPrompts`, mounted in the
 * root layout) mounts and calls `enableMcpConfirmationUi()` does the gate switch to "put the request
 * in the store and wait for the user's choice". This way an "ask every time" tool is never executed
 * just because no UI was attached to stop it.
 *
 * The host lives in the root layout rather than the chat page: while a reply keeps running in the
 * background the user may go to settings or another conversation, and the confirmation dialog and
 * the "authorization expired" pause prompt follow them. Mounted in the chat page, leaving that page
 * would amount to pressing "deny" on the user's behalf.
 */

import { create } from 'zustand';
import {
  McpConversationGrants,
  denyingMcpConfirmationGate,
  type McpConfirmationChoice,
  type McpConfirmationGate,
  type McpConfirmationRequest,
  type McpReauthorizationChoice,
  type McpReauthorizationGate,
  type McpReauthorizationRequest,
} from '@oriveo/core/mcp/index';

/** One confirmation waiting for the user's choice. The UI shows only the one for the current `conversationId` (head of the queue). */
export interface McpPendingConfirmation {
  id: string;
  request: McpConfirmationRequest;
}

interface McpConfirmationState {
  pending: McpPendingConfirmation[];
}

export const useMcpConfirmationStore = create<McpConfirmationState>(() => ({ pending: [] }));

const resolvers = new Map<string, (choice: McpConfirmationChoice) => void>();
let sequence = 0;

function settle(id: string, choice: McpConfirmationChoice): void {
  const resolve = resolvers.get(id);
  if (!resolve) return;
  resolvers.delete(id);
  useMcpConfirmationStore.setState((state) => ({ pending: state.pending.filter((item) => item.id !== id) }));
  resolve(choice);
}

/** Called by the three buttons of the confirmation dialog. Each id takes effect only once. */
export function resolveMcpConfirmation(id: string, choice: McpConfirmationChoice): void {
  settle(id, choice);
}

/** The gate that puts the request in the store and waits for the user's choice. When the user presses stop (`signal` aborts) the wait ends as a denial. */
export const storeMcpConfirmationGate: McpConfirmationGate = {
  requestConfirmation(request, signal) {
    if (signal.aborted) return Promise.resolve('deny');
    sequence += 1;
    const id = `mcp-confirm-${sequence}`;
    return new Promise<McpConfirmationChoice>((resolve) => {
      const onAbort = () => settle(id, 'deny');
      resolvers.set(id, (choice) => {
        signal.removeEventListener('abort', onAbort);
        resolve(choice);
      });
      signal.addEventListener('abort', onAbort, { once: true });
      useMcpConfirmationStore.setState((state) => ({ pending: [...state.pending, { id, request }] }));
    });
  },
};

let activeGate: McpConfirmationGate = denyingMcpConfirmationGate;

/** The gate used by the send path. */
export function currentMcpConfirmationGate(): McpConfirmationGate {
  return activeGate;
}

/**
 * Called when the global prompt host mounts; returns the function to call on unmount. After unmount
 * the gate denies everything again and every request still pending ends as a denial, because with
 * no UI left nobody can allow them.
 */
export function enableMcpConfirmationUi(): () => void {
  activeGate = storeMcpConfirmationGate;
  activeReauthGate = storeMcpReauthorizationGate;
  return () => {
    if (activeGate === storeMcpConfirmationGate) activeGate = denyingMcpConfirmationGate;
    if (activeReauthGate === storeMcpReauthorizationGate) activeReauthGate = null;
    for (const id of [...resolvers.keys()]) settle(id, 'deny');
    for (const id of [...reauthResolvers.keys()]) settleReauth(id, 'skip');
  };
}

// ── Authorization expired mid-reply ─────────────────────────────────────

/** A step paused at "waiting for re-authorization". The step block attaches the two buttons under that row by `stepId`. */
export interface McpPendingReauthorization {
  id: string;
  request: McpReauthorizationRequest;
}

export const useMcpReauthorizationStore = create<{ pending: McpPendingReauthorization[] }>(() => ({ pending: [] }));

const reauthResolvers = new Map<string, (choice: McpReauthorizationChoice) => void>();

function settleReauth(id: string, choice: McpReauthorizationChoice): void {
  const resolve = reauthResolvers.get(id);
  if (!resolve) return;
  reauthResolvers.delete(id);
  useMcpReauthorizationStore.setState((state) => ({ pending: state.pending.filter((item) => item.id !== id) }));
  resolve(choice);
}

/** Called by the two buttons on the step block: `reauthorized` after a successful sign-in, `skip` for "skip this step". */
export function resolveMcpReauthorization(id: string, choice: McpReauthorizationChoice): void {
  settleReauth(id, choice);
}

/** The gate that puts "this step is waiting for re-authorization" in the store. When the user presses stop the wait ends as a skip (the executor then sees the cancellation). */
export const storeMcpReauthorizationGate: McpReauthorizationGate = {
  requestReauthorization(request, signal) {
    if (signal.aborted) return Promise.resolve('skip');
    sequence += 1;
    const id = `mcp-reauth-${sequence}`;
    return new Promise<McpReauthorizationChoice>((resolve) => {
      const onAbort = () => settleReauth(id, 'skip');
      reauthResolvers.set(id, (choice) => {
        signal.removeEventListener('abort', onAbort);
        resolve(choice);
      });
      signal.addEventListener('abort', onAbort, { once: true });
      useMcpReauthorizationStore.setState((state) => ({ pending: [...state.pending, { id, request }] }));
    });
  },
};

let activeReauthGate: McpReauthorizationGate | null = null;

/** Used by the send path. Null when there is no chat UI: the loop does not pause and the step degrades straight to `needs_auth`. */
export function currentMcpReauthorizationGate(): McpReauthorizationGate | null {
  return activeReauthGate;
}

// ── Which conversation's chat page is on screen ─────────────────────────

/**
 * Conversation ids of the chat pages currently on screen (counted, since the old and new page can
 * briefly coexist while switching conversations). The "authorization expired" pause prompt normally
 * sits under that message's step block; when the conversation is not on screen the global host
 * shows a separate dialog instead.
 */
export const useMcpVisibleChatStore = create<{ visible: Record<string, number> }>(() => ({ visible: {} }));

/** Called when the chat page mounts or switches to a conversation; returns the function to call on leaving. */
export function markMcpChatVisible(conversationId: string): () => void {
  useMcpVisibleChatStore.setState((state) => ({ visible: { ...state.visible, [conversationId]: (state.visible[conversationId] ?? 0) + 1 } }));
  return () => {
    useMcpVisibleChatStore.setState((state) => {
      const { [conversationId]: count = 0, ...rest } = state.visible;
      return { visible: count > 1 ? { ...rest, [conversationId]: count - 1 } : rest };
    });
  };
}

/** Test injection; pass null to return to the default (deny everything). */
export function __setMcpConfirmationGateForTests(gate: McpConfirmationGate | null): void {
  activeGate = gate ?? denyingMcpConfirmationGate;
}

/** In-memory grants for "allow for this conversation": one instance per page, gone on reload, never written to any storage. */
export const mcpConversationGrants = new McpConversationGrants();
