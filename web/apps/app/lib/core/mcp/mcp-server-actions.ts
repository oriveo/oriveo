/**
 * Operations on a saved server: re-reading tools, confirming tool changes, re-authorizing, and
 * replacing the access token. The management page, the tools panel and the "re-authorize" button on
 * the step block all go through here; components never touch the protocol client or the authorizer
 * directly.
 *
 * Each operation ends by writing the connection state back to local storage (`connected` /
 * `needsAuth` / `unreachable`), which is where the status pill and the tools panel rows read it.
 */

import {
  McpAuthorizerError,
  McpClientError,
  buildToolSnapshots,
  confirmToolSnapshots,
  diffToolSnapshots,
  type McpAuthorizationLauncher,
  type McpAuthorizationPlan,
  type McpClient,
  type McpConnectionStatus,
  type McpSession,
  type McpToolChange,
  type McpToolDefinition,
  type McpToolPermission,
  type McpToolSnapshot,
} from '@oriveo/core/mcp/index';
import { createMcpClient, currentMcpRuntimeConfig, getMcpAuthorizer, getMcpCredentialStore, useMcpStore } from './mcp-store';
import { mcpHostname } from './mcp-presentation';

function requireServer(serverId: string) {
  const state = useMcpStore.getState();
  const record = state.servers.find((server) => server.id === serverId);
  if (!state.uid || !record) return null;
  return { uid: state.uid, record };
}

async function saveStatus(serverId: string, status: McpConnectionStatus, session?: McpSession | null): Promise<void> {
  const store = useMcpStore.getState();
  const current = store.connections[serverId];
  try {
    await store.saveConnectionState({
      serverId,
      status,
      lastSuccessAt: status === 'connected' ? Date.now() : current?.lastSuccessAt ?? null,
      negotiatedVersion: session?.protocolVersion ?? current?.negotiatedVersion ?? null,
      generation: session?.generation ?? current?.generation ?? null,
      sessionId: status === 'connected' ? session?.sessionId ?? null : null,
    });
  } catch {
    // A failed state write does not affect this operation's result; the next probe writes it again.
  }
}

type Connected = { kind: 'connected'; client: McpClient; session: McpSession };
type ConnectFailure = { kind: 'needsAuth'; client: McpClient } | { kind: 'unreachable' };

/** Connects once with the locally stored token (refreshing first if it is about to expire). Never signs in again. */
async function connectSaved(serverId: string, signal?: AbortSignal): Promise<Connected | ConnectFailure | null> {
  const target = requireServer(serverId);
  if (!target) return null;
  const client = createMcpClient(target.record.url);
  let token: string | null;
  try {
    token = await getMcpAuthorizer(target.uid).validAccessToken(serverId, target.uid);
  } catch (error) {
    // A transient error (network / 5xx) does not mean a new sign-in is required.
    if (error instanceof McpAuthorizerError && error.isTransient) return { kind: 'unreachable' };
    return { kind: 'needsAuth', client };
  }
  const outcome = await client.connect({ bearerToken: token, signal });
  if (outcome.kind === 'connected') return { kind: 'connected', client, session: outcome.session };
  if (outcome.kind === 'needsAuth') return { kind: 'needsAuth', client };
  return { kind: 'unreachable' };
}

// ── Re-reading tools ────────────────────────────────────────────────────

export type McpRefreshResult =
  | { status: 'connected'; changes: McpToolChange[] }
  | { status: 'needsAuth' }
  | { status: 'unreachable' }
  /** The server is no longer in the list (removed in another tab) or the store has not hydrated yet. */
  | { status: 'gone' };

/**
 * Rules for persisting a new catalog: added and changed tools go back into quarantine
 * (`buildToolSnapshots`), and permission records of removed tools are cleared. Added tools get
 * **no permission written in advance**; the default is only chosen at confirmation, which lets the
 * UI tell "added" (no permission record) from "description changed" (has one).
 */
async function saveCatalog(serverId: string, definitions: readonly McpToolDefinition[]): Promise<McpToolChange[]> {
  const store = useMcpStore.getState();
  const existing = store.snapshots[serverId] ?? [];
  const incoming = buildToolSnapshots({ serverId, definitions, runtimeConfig: currentMcpRuntimeConfig(), existing });
  const changes = diffToolSnapshots(existing, incoming);
  const names = new Set(incoming.map((snapshot) => snapshot.toolName));
  const permissions: Record<string, McpToolPermission> = {};
  for (const [toolName, permission] of Object.entries(store.permissions[serverId] ?? {})) {
    if (names.has(toolName)) permissions[toolName] = permission;
  }
  await store.saveToolCatalog(serverId, incoming, permissions);
  return changes;
}

export async function refreshMcpServerTools(serverId: string, options: { signal?: AbortSignal } = {}): Promise<McpRefreshResult> {
  const connection = await connectSaved(serverId, options.signal);
  if (!connection) return { status: 'gone' };
  if (connection.kind !== 'connected') {
    await saveStatus(serverId, connection.kind);
    return { status: connection.kind };
  }
  let definitions: McpToolDefinition[];
  try {
    definitions = await connection.client.listTools({ signal: options.signal });
  } catch (error) {
    const status = error instanceof McpClientError && error.code === 'needs_auth' ? 'needsAuth' : 'unreachable';
    await saveStatus(serverId, status);
    return { status };
  }
  if (!requireServer(serverId)) return { status: 'gone' };
  const changes = await saveCatalog(serverId, definitions);
  await saveStatus(serverId, 'connected', connection.session);
  return { status: 'connected', changes };
}

/** Probes the connection state only (the "refresh" action on the list page): does not read the tool list or touch the catalog. */
export async function probeMcpServer(serverId: string, options: { signal?: AbortSignal } = {}): Promise<McpConnectionStatus | 'gone'> {
  const connection = await connectSaved(serverId, options.signal);
  if (!connection) return 'gone';
  await saveStatus(serverId, connection.kind, connection.kind === 'connected' ? connection.session : null);
  return connection.kind;
}

// ── Confirming tool changes ─────────────────────────────────────────────

export interface McpPendingToolChange {
  /** A quarantined tool with no permission record is newly added; one with a record had its description, parameters or title changed. */
  kind: 'added' | 'changed';
  snapshot: McpToolSnapshot;
  /** The permission that takes effect after confirmation (the default for added tools; changed tools can only be lowered, never raised). */
  permissionAfter: McpToolPermission;
}

/** Tools on this server waiting for the user's confirmation (the quarantined ones in the local snapshots). */
export function pendingMcpToolChanges(
  snapshots: readonly McpToolSnapshot[],
  permissions: Readonly<Record<string, McpToolPermission>>,
): McpPendingToolChange[] {
  return snapshots
    .filter((snapshot) => snapshot.pendingReview)
    .map((snapshot) => {
      const current = permissions[snapshot.toolName];
      const permissionAfter: McpToolPermission =
        current === undefined ? (snapshot.readOnly ? 'auto' : 'ask') : current === 'auto' && !snapshot.readOnly ? 'ask' : current;
      return { kind: current === undefined ? 'added' : 'changed', snapshot, permissionAfter };
    });
}

export type McpConfirmChangesResult =
  /** `stillPending`: tools the server changed again during confirmation; they stay quarantined and the UI has the user review them once more. */
  | { status: 'confirmed'; stillPending: string[] }
  | { status: 'needsAuth' }
  | { status: 'unreachable' }
  | { status: 'gone' };

/**
 * The user confirms changes. **What gets confirmed is the snapshot the user saw**: the definitions
 * are fetched from the server once more, and only tools whose hash and title still match what the
 * user saw leave quarantine. Tools that no longer match stay quarantined, and the server's current
 * definition is stored as a new snapshot pending review.
 */
export async function confirmMcpToolChanges(serverId: string, options: { signal?: AbortSignal } = {}): Promise<McpConfirmChangesResult> {
  const connection = await connectSaved(serverId, options.signal);
  if (!connection) return { status: 'gone' };
  if (connection.kind !== 'connected') {
    await saveStatus(serverId, connection.kind);
    return { status: connection.kind };
  }
  let definitions: McpToolDefinition[];
  try {
    definitions = await connection.client.listTools({ signal: options.signal });
  } catch (error) {
    const status = error instanceof McpClientError && error.code === 'needs_auth' ? 'needsAuth' : 'unreachable';
    await saveStatus(serverId, status);
    return { status };
  }
  const store = useMcpStore.getState();
  if (!requireServer(serverId)) return { status: 'gone' };
  const runtimeConfig = currentMcpRuntimeConfig();
  const seen = store.snapshots[serverId] ?? [];
  const confirmation = confirmToolSnapshots({
    snapshots: seen,
    definitions,
    permissions: store.permissions[serverId] ?? {},
    runtimeConfig,
  });
  // The server's full current set: confirmed tools stay released; tools that changed again during
  // confirmation, and ones that appeared meanwhile, are quarantined under their latest definition.
  const confirmed = confirmation.snapshots.filter((snapshot) => !snapshot.pendingReview);
  const next = buildToolSnapshots({ serverId, definitions, runtimeConfig, existing: confirmed });
  const names = new Set(next.map((snapshot) => snapshot.toolName));
  const permissions: Record<string, McpToolPermission> = {};
  for (const [toolName, permission] of Object.entries(confirmation.permissions)) {
    if (names.has(toolName)) permissions[toolName] = permission;
  }
  await store.saveToolCatalog(serverId, next, permissions);
  await saveStatus(serverId, 'connected', connection.session);
  return { status: 'confirmed', stillPending: next.filter((snapshot) => snapshot.pendingReview).map((snapshot) => snapshot.toolName) };
}

/**
 * The final "done" step of the add flow: the user has reviewed the tool groups and default
 * permissions, and pressing done confirms this set of tools. The probe has just read exactly this
 * snapshot, so the server is not asked a second time. `permissions` is what the user adjusted on
 * that page.
 *
 * The record is confirmed first (from then on it is not cleaned up as half-finished on the next
 * load) and the permissions are saved after: if the permission write fails the tools
 * merely stay quarantined and the server is not lost.
 */
export async function acceptMcpAddedTools(serverId: string, permissions: Record<string, McpToolPermission>): Promise<void> {
  const store = useMcpStore.getState();
  await store.confirmServerAdded(serverId);
  const snapshots = (store.snapshots[serverId] ?? []).map((snapshot) => ({ ...snapshot, pendingReview: false }));
  await store.saveToolCatalog(serverId, snapshots, permissions);
}

// ── Re-authorization ────────────────────────────────────────────────────

export type McpReauthPreparation =
  /** Browser sign-in is possible: the UI first shows the pre-sign-in notice, then calls `completeMcpReauthorization` once the user agrees. */
  | { kind: 'ready'; plan: McpAuthorizationPlan; authorizationHost: string; serverHost: string }
  /** This server uses an access token, or does not support automatic sign-in: the UI shows a token input. */
  | { kind: 'needsToken' }
  /** It actually connects (already signed in elsewhere, or the token refresh succeeded). */
  | { kind: 'connected' }
  | { kind: 'unreachable' }
  | { kind: 'gone' };

/** First step of re-authorization: reads metadata only (GET), with no registration and no window. */
export async function prepareMcpReauthorization(serverId: string, options: { signal?: AbortSignal } = {}): Promise<McpReauthPreparation> {
  const target = requireServer(serverId);
  if (!target) return { kind: 'gone' };
  const connection = await connectSaved(serverId, options.signal);
  if (!connection) return { kind: 'gone' };
  if (connection.kind === 'connected') {
    await saveStatus(serverId, 'connected', connection.session);
    return { kind: 'connected' };
  }
  if (connection.kind === 'unreachable') return { kind: 'unreachable' };
  if (target.record.authKind === 'token') return { kind: 'needsToken' };
  const discovery = await getMcpAuthorizer(target.uid).discover(connection.client.authChallenge, target.record.url);
  if (discovery.kind === 'temporarilyUnavailable') return { kind: 'unreachable' };
  if (discovery.kind === 'needsToken') return { kind: 'needsToken' };
  return {
    kind: 'ready',
    plan: discovery.plan,
    authorizationHost: mcpHostname(discovery.plan.authorizationEndpoint),
    serverHost: mcpHostname(target.record.url),
  };
}

export type McpReauthOutcome = 'connected' | 'cancelled' | 'unreachable' | 'failed' | 'gone';

/**
 * Second step of re-authorization: register, open the authorization page, exchange the code for
 * tokens, then connect once with the new token. The `launcher` window must already have been opened
 * synchronously in the user's click handler (see `createPreopenedMcpAuthorization`).
 */
export async function completeMcpReauthorization(
  serverId: string,
  plan: McpAuthorizationPlan,
  launcher: McpAuthorizationLauncher,
  options: { signal?: AbortSignal } = {},
): Promise<McpReauthOutcome> {
  const target = requireServer(serverId);
  if (!target) return 'gone';
  try {
    await getMcpAuthorizer(target.uid).authorize(plan, serverId, target.uid, { signal: options.signal, launcher });
  } catch (error) {
    if (error instanceof McpAuthorizerError) {
      if (error.isTransient) return 'unreachable';
      return error.kind === 'cancelled' ? 'cancelled' : 'failed';
    }
    return 'failed';
  }
  return finishReauthorization(serverId, options.signal);
}

/** Replaces the access token of a saved server (from the token input). The token is not saved if the server rejects it. */
export async function submitMcpAccessToken(serverId: string, token: string, options: { signal?: AbortSignal } = {}): Promise<'connected' | 'rejected' | 'unreachable' | 'gone'> {
  const target = requireServer(serverId);
  const trimmed = token.trim();
  if (!target) return 'gone';
  if (!trimmed) return 'rejected';
  const client = createMcpClient(target.record.url);
  const outcome = await client.connect({ bearerToken: trimmed, signal: options.signal });
  if (outcome.kind === 'needsAuth') return 'rejected';
  if (outcome.kind !== 'connected') return 'unreachable';
  try {
    await getMcpAuthorizer(target.uid).storePastedToken(trimmed, serverId, target.uid);
  } catch {
    return 'unreachable';
  }
  const finished = await finishReauthorization(serverId, options.signal);
  return finished === 'connected' ? 'connected' : finished === 'gone' ? 'gone' : 'unreachable';
}

/** New credentials obtained: connect once and refresh the tool catalog along the way (tools that changed meanwhile go back into quarantine as usual). */
async function finishReauthorization(serverId: string, signal?: AbortSignal): Promise<McpReauthOutcome> {
  const refreshed = await refreshMcpServerTools(serverId, { signal });
  if (refreshed.status === 'connected') return 'connected';
  if (refreshed.status === 'gone') return 'gone';
  // The server still demands sign-in right after signing in: treat it as a failure and keep the
  // credentials (the next refresh or sign-in overwrites them).
  return refreshed.status === 'needsAuth' ? 'failed' : 'unreachable';
}

/** Whether credentials for this server are stored on this device (for the "sign-in method" row of the detail page). */
export async function mcpServerHasCredentials(serverId: string): Promise<boolean> {
  const target = requireServer(serverId);
  if (!target) return false;
  try {
    return (await getMcpCredentialStore(target.uid).load(serverId, target.uid)) !== null;
  } catch {
    return false;
  }
}
