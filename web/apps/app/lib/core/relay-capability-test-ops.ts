import type { StoreApi } from 'zustand';
import type { AIModel, Provider, RelayCapabilityOverrides } from '@oriveo/shared';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import {
  RELAY_CAPABILITY_TEST_DEADLINE_MS,
  RELAY_CAPABILITY_TEST_MAX_OUTPUT_TOKENS,
  classifyRelayCapabilityTestOutcome,
  judgeRelayCapabilityTestResponse,
  relayCapabilityTestFunctionTool,
  relayCapabilityTestMessages,
  relayCapabilityTestShortTransport,
  type RelayCapabilityTestReason,
  type RelayCapabilityTestShortTransport,
  type RelayCapabilityTestVerdict,
} from '@oriveo/core/providers/relay-capability-test';
import type { RelayWireRequest } from '@oriveo/core/providers/relay-orchestrator';
import type { RelayWebProbeResult } from '@oriveo/core/providers/relay-web-probe';
import type { StreamOptions } from './providers/types';
import type { AppStore } from './store/app-store';
import { sameNormalizedID } from '../utils/id-utils';
import { buildRelayChatRequest, webRelayTransport } from './providers/adapters/relay';
import { buildProviderStreamOptions } from './chat/stream-options';
import { canProbeRelayModels, relayProbeConnectionIdentity } from './relay-model-probe-ops';
import { clearRelayNegativeCache } from './chat/relay-negative-cache';
import { relayFirstSendTransport } from './providers/relay-first-send-transport';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { relayGenerationKeyStatus } from '@oriveo/core/providers/relay-key-access';
import { recordRelayGenerationKeyStatus } from './providers/relay-key-access-writeback';
import { withErrorReporting } from '../sentry/report-silent';
import { relayWebFragmentForTransport } from './chat/relay-web-fragments';
import { runRelayWebProbe, type RelayWebProbeStopReason } from './relay-web-probe-ops';

/**
 * Relay user-initiated "test capability" (C3 section 3.6; fixture capability-test.v1.json):
 * by the model's current effective transport, send text → image → tool in turn, one streaming request per item, produced by the same builder and transport as normal chat,
 * sent only once (no fallback / self-heal / retry / negative-cache write), each item with a 30-second total limit. If text fails, stop and write nothing;
 * write only the image / toolCall items, items overridden by the user are neither sent nor changed. Before each item is sent and before write-back, check connection / transport / testability;
 * on change, stop and give the reason; the readings of completed items are kept but not written.
 */

export type RelayCapabilityTestItem = 'image' | 'toolCall';
/** Items in the panel and results: text + vision + tool calling + web (the web item goes last when the first-send transport has a stored snippet). */
export type RelayCapabilityTestPanelKind = 'text' | RelayCapabilityTestItem | 'web';
export type RelayCapabilityTestStopReason = 'cancelled' | 'connection' | 'protocol' | 'unavailable';

export interface RelayCapabilityTestResponse {
  status: number;
  contentType: string | null;
  body: string;
}

/** Send one test request and read the whole response; throw when there is no HTTP response (network error / aborted). HTTP errors do not throw and are returned as responses. */
export type RelayCapabilityTestSend = (
  request: RelayWireRequest,
  signal: AbortSignal,
) => Promise<RelayCapabilityTestResponse>;

export interface RelayCapabilityTestItemResult {
  /** The web item's reading is the web-probe result (searched / silent / rejected / undetermined). */
  verdict: RelayCapabilityTestVerdict | RelayWebProbeResult;
  reason: RelayCapabilityTestReason;
  /** Status code when there is an HTTP response. */
  status?: number;
  elapsedMs: number;
}

export type RelayCapabilityTestResults = Partial<Record<RelayCapabilityTestPanelKind, RelayCapabilityTestItemResult>>;

export interface RelayCapabilityTestProgress {
  /** The item being sent; null = just finished reading one item. */
  running: RelayCapabilityTestPanelKind | null;
  results: RelayCapabilityTestResults;
}

export interface RelayCapabilityTestResult {
  outcome: 'completed' | 'text_failed' | 'stopped';
  /** Items to be tested (text + vision / tools not set by the user). */
  plan: RelayCapabilityTestPanelKind[];
  results: RelayCapabilityTestResults;
  /** Readings of image / toolCall (same shape as fixture expect.items). */
  items: Partial<Record<RelayCapabilityTestItem, RelayCapabilityTestVerdict>>;
  stopReason?: RelayCapabilityTestStopReason;
  /** A write-back happened (only in completed). */
  written: boolean;
  /** Error thrown after the write to the store (e.g. sync): the result still counts as written, and the error is handed out together. */
  error?: unknown;
}

const ITEMS: ReadonlyArray<RelayCapabilityTestItem> = ['image', 'toolCall'];

function findProvider(store: StoreApi<AppStore>, providerID: string): Provider | undefined {
  return store.getState().providers.find((item) => sameNormalizedID(item.id, providerID));
}

/** Capability test uses the same path as chat (RL2-CAPTEST-FIRSTSEND): request, key clearing, panel display and eligibility all follow the first-send transport without attachments. */
export function relayCapabilityTestTransport(provider: Provider, model: AIModel): RelayCapabilityTestShortTransport | undefined {
  return relayCapabilityTestShortTransport(relayFirstSendTransport(provider, model));
}

/** The connection is within the per-model probe scope, and the model's first-send transport is one of chat / responses / messages / gemini. */
function canSendRelayCapabilityTest(provider: Provider, model: AIModel): boolean {
  return canProbeRelayModels(provider)
    && relayCapabilityTestTransport(provider, model) !== undefined;
}

/**
 * Entry: a test can be sent, and vision and tools are not both already hand-selected by the user;
 * if both are hand-selected but the web item is listable (the first-send transport has a stored snippet), still provide the entry (unified across all three platforms).
 */
export function canTestRelayModelCapabilities(provider: Provider, model: AIModel): boolean {
  if (!canSendRelayCapabilityTest(provider, model)) return false;
  const overrides = model.relayCapabilityOverrides;
  const allUserSet = ITEMS.every((item) => overrides?.[item]?.source === 'user');
  return !allUserSet || relayCapabilityTestPlan(model, provider).includes('web');
}

/**
 * Items to be tested: text always first; vision / tools only when not set by the user;
 * web last, listed only when the model's first-send transport has a stored snippet.
 */
export function relayCapabilityTestPlan(model: AIModel, provider?: Provider): RelayCapabilityTestPanelKind[] {
  const plan: RelayCapabilityTestPanelKind[] = [
    'text',
    ...ITEMS.filter((item) => model.relayCapabilityOverrides?.[item]?.source !== 'user'),
  ];
  if (provider && relayWebFragmentForTransport(provider, relayFirstSendTransport(provider, model))) plan.push('web');
  return plan;
}

/** Web-probe interruption reason → capability-test interruption reason; a snippet edited / deleted while running is reported as "transport changed". */
function capabilityStopReason(reason: RelayWebProbeStopReason | undefined): RelayCapabilityTestStopReason {
  switch (reason) {
    case 'cancelled':
    case 'connection':
    case 'protocol':
    case 'unavailable':
      return reason;
    default:
      return 'protocol';
  }
}

export function hasTestedRelayCapabilityOverrides(model: Pick<AIModel, 'relayCapabilityOverrides'>): boolean {
  return Object.values(model.relayCapabilityOverrides ?? {}).some((entry) => entry?.source === 'tested');
}

/**
 * Chat options for one test item: the same option builder as normal chat (transport, root address, auth, headers, evidence and connection identity),
 * without the user's generation parameters / extra request body; streaming forced, output cap 16, and tool items additionally carry the single function tool.
 */
export function relayCapabilityTestStreamOptions(
  provider: Provider,
  model: AIModel,
  kind: RelayCapabilityTestPanelKind,
): StreamOptions {
  // When the first-send transport differs from the effective one (an unverified model switching transport on first send), re-resolve the runtime by the first-send transport, the same construction as chat first send.
  const firstSend = relayFirstSendTransport(provider, model);
  const sendModel = firstSend === effectiveTransport(provider, model) ? model : { ...model, relayTransport: firstSend };
  return {
    ...buildProviderStreamOptions(provider, undefined, sendModel),
    // Capability test tests only the model itself and carries no connection-level web snippet.
    relayWebFragment: undefined,
    relayStream: true,
    relayMaxOutputTokens: RELAY_CAPABILITY_TEST_MAX_OUTPUT_TOKENS,
    ...(kind === 'toolCall' ? { relayFunctionTool: relayCapabilityTestFunctionTool() } : {}),
  };
}

/** Read the whole response body; on abort cancel the read (a stream that drips comment lines also stops). */
async function readFullBody(response: Response, signal: AbortSignal): Promise<string> {
  if (!response.body) return '';
  const reader = response.body.getReader();
  const cancel = () => { void reader.cancel().catch(() => undefined); };
  signal.addEventListener('abort', cancel, { once: true });
  const decoder = new TextDecoder();
  let text = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      text += decoder.decode(value, { stream: true });
    }
    return text + decoder.decode();
  } finally {
    signal.removeEventListener('abort', cancel);
  }
}

/** Production send: the same transport as chat (browser public network via /api/relay/forward, LAN direct); reads status / content-type / the whole body. */
export const sendViaChatTransport: RelayCapabilityTestSend = async (request, signal) => {
  const response = await webRelayTransport.fetch(request.url, {
    method: request.method,
    headers: request.headers,
    body: request.body,
    signal,
  });
  const body = await readFullBody(response, signal);
  return { status: response.status, contentType: response.headers.get('Content-Type'), body };
};

type ItemRun = RelayCapabilityTestItemResult | 'cancelled';

async function runItem(
  provider: Provider,
  model: AIModel,
  kind: Exclude<RelayCapabilityTestPanelKind, 'web'>,
  send: RelayCapabilityTestSend,
  signal: AbortSignal | undefined,
  deadlineMs: number,
  now: () => number,
  onResponse?: (response: RelayCapabilityTestResponse) => void,
): Promise<ItemRun> {
  const startedAt = now();
  const elapsed = () => Math.max(0, now() - startedAt);
  let request: RelayWireRequest;
  try {
    request = buildRelayChatRequest(
      resolveProviderAPIKey(provider, model.id),
      model.id,
      relayCapabilityTestMessages(kind === 'toolCall' ? 'tool' : kind),
      provider.baseURLText,
      relayCapabilityTestStreamOptions(provider, model, kind),
    );
  } catch {
    // Address / security policy rejected: no request sent, cannot be judged.
    return { verdict: 'undetermined', reason: 'network', elapsedMs: elapsed() };
  }
  const sent = await sendRelayTestRequestOnce(request, send, signal, deadlineMs);
  if (sent === 'cancelled') return 'cancelled';
  if (sent === 'timeout' || sent === 'network') return { verdict: 'undetermined', reason: sent, elapsedMs: elapsed() };
  onResponse?.(sent);
  // After a 2xx for vision / tools is accepted, run production parsing to find evidence, and parsing uses this request's first-send transport.
  const outcome = await judgeRelayCapabilityTestResponse(
    kind === 'toolCall' ? 'tool' : kind,
    relayFirstSendTransport(provider, model),
    sent,
  );
  return { ...outcome, status: sent.status, elapsedMs: elapsed() };
}

/**
 * Send one test request (shared by capability test and web probe): the total limit covers the whole read, external cancellation is forwarded to the request;
 * no retry / fallback. Returns cancelled / timeout / network when there is no HTTP response.
 */
export async function sendRelayTestRequestOnce(
  request: RelayWireRequest,
  send: RelayCapabilityTestSend,
  signal: AbortSignal | undefined,
  deadlineMs: number,
): Promise<RelayCapabilityTestResponse | 'cancelled' | 'timeout' | 'network'> {
  if (signal?.aborted) return 'cancelled';

  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, deadlineMs);
  const forwardAbort = () => controller.abort();
  signal?.addEventListener('abort', forwardAbort, { once: true });
  // The total limit covers the whole read: even if the sender ignores the signal it closes on time.
  const aborted = new Promise<never>((_resolve, reject) => {
    controller.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
  });
  try {
    return await Promise.race([send(request, controller.signal), aborted]);
  } catch {
    if (signal?.aborted) return 'cancelled';
    return timedOut ? 'timeout' : 'network';
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', forwardAbort);
  }
}

/**
 * T3: run the capability test on an enabled model. Always returns a result (no longer null):
 * accepted writes {true, tested}, rejected writes {false, tested}, undetermined / notObserved write nothing (keep the old value);
 * an interruption (cancel / connection changed / transport changed / model no longer testable) returns stopped + reason, completed items are kept and not written.
 */
export async function runRelayCapabilityTest(
  store: StoreApi<AppStore>,
  providerID: string,
  modelID: string,
  deps: {
    send?: RelayCapabilityTestSend;
    signal?: AbortSignal;
    /** Total limit per item; production = 30 seconds, tests inject a short value. */
    deadlineMs?: number;
    onProgress?: (progress: RelayCapabilityTestProgress) => void;
    now?: () => number;
  } = {},
): Promise<RelayCapabilityTestResult> {
  const send = deps.send ?? sendViaChatTransport;
  const { signal, onProgress } = deps;
  const deadlineMs = deps.deadlineMs ?? RELAY_CAPABILITY_TEST_DEADLINE_MS;
  const now = deps.now ?? (() => Date.now());

  const provider = findProvider(store, providerID);
  const model = provider?.models.find((item) => item.id === modelID);
  const plan = model ? relayCapabilityTestPlan(model, provider) : ['text', ...ITEMS] as RelayCapabilityTestPanelKind[];
  const results: RelayCapabilityTestResults = {};
  const finish = (
    outcome: RelayCapabilityTestResult['outcome'],
    extra: Partial<Pick<RelayCapabilityTestResult, 'stopReason' | 'written' | 'error'>> = {},
  ): RelayCapabilityTestResult => ({
    outcome,
    plan,
    results: { ...results },
    items: Object.fromEntries(ITEMS.flatMap((item) => results[item] ? [[item, results[item]!.verdict]] : [])),
    written: false,
    ...extra,
  });
  if (!provider || !model || !canSendRelayCapabilityTest(provider, model)) {
    return finish('stopped', { stopReason: 'unavailable' });
  }

  const identity = relayProbeConnectionIdentity(provider, modelID);
  const transport = relayFirstSendTransport(provider, model);
  /**
   * Checked before each item is sent and before write-back: cancel → model not testable → connection identity → effective transport.
   * On pass, hand out the latest provider / model read this time, and the request is built from it.
   */
  const checkNow = (): { stop: RelayCapabilityTestStopReason } | { provider: Provider; model: AIModel } => {
    if (signal?.aborted) return { stop: 'cancelled' };
    const latest = findProvider(store, providerID);
    const latestModel = latest?.models.find((entry) => entry.id === modelID);
    if (!latest || !latestModel || !canSendRelayCapabilityTest(latest, latestModel)) return { stop: 'unavailable' };
    if (relayProbeConnectionIdentity(latest, modelID) !== identity) return { stop: 'connection' };
    if (relayFirstSendTransport(latest, latestModel) !== transport) return { stop: 'protocol' };
    return { provider: latest, model: latestModel };
  };

  // The web item's override is written back by the web probe itself (searched / rejected write tested web), which also counts as a write this time.
  let webWritten = false;
  for (const kind of plan) {
    const check = checkNow();
    if ('stop' in check) return finish('stopped', { stopReason: check.stop });
    onProgress?.({ running: kind, results: { ...results } });
    if (kind === 'web') {
      // Manual web probe (web-probe.v1.json triggers): no cap, no de-duplication, not into the automatic history.
      const startedAt = now();
      const probe = await runRelayWebProbe(store, providerID, modelID, {
        send,
        signal,
        ...(deps.deadlineMs !== undefined ? { deadlineMs: deps.deadlineMs } : {}),
        now,
      });
      if (probe.outcome !== 'completed' || !probe.result) {
        return finish('stopped', {
          stopReason: probe.outcome === 'unavailable' ? 'unavailable' : capabilityStopReason(probe.stopReason),
        });
      }
      results.web = {
        verdict: probe.result,
        reason: probe.reason ?? 'ok',
        ...(probe.status !== undefined ? { status: probe.status } : {}),
        elapsedMs: Math.max(0, now() - startedAt),
      };
      webWritten = probe.overrideWritten;
      onProgress?.({ running: null, results: { ...results } });
      continue;
    }
    // Every item's request writes the effective key's status: only those with an HTTP response count; if the connection identity changed during the request, the write-back discards it.
    // A status write-back failure does not interrupt the capability test (it is not an output of this test).
    const writeKeyStatus = (response: RelayCapabilityTestResponse) => {
      // A 2xx counts as normal only when this platform judges it a truly successful one (accepted); web pages / undecodable content / error bodies are not written.
      const success = response.status >= 200 && response.status < 300;
      const keyStatus = success
        ? (classifyRelayCapabilityTestOutcome(response).verdict === 'accepted' ? 'ok' : null)
        : relayGenerationKeyStatus(response.status, response.body);
      try {
        recordRelayGenerationKeyStatus(store, check.provider, check.model, keyStatus, response.status);
      } catch (error) {
        withErrorReporting('relay.capability_test_key_status')(error);
      }
    };
    const run = await runItem(check.provider, check.model, kind, send, signal, deadlineMs, now, writeKeyStatus);
    if (run === 'cancelled') return finish('stopped', { stopReason: 'cancelled' });
    results[kind] = run;
    onProgress?.({ running: null, results: { ...results } });
    if (kind === 'text' && run.verdict !== 'accepted') return finish('text_failed');
  }

  const check = checkNow();
  if ('stop' in check) return finish('stopped', { stopReason: check.stop });

  const writes = ITEMS.filter((item) => results[item]?.verdict === 'accepted' || results[item]?.verdict === 'rejected');
  if (writes.length === 0) return finish('completed', { written: webWritten });
  let stored = false;
  try {
    writeOverrides(store, check.provider, modelID, (current) => {
      const next: RelayCapabilityOverrides = { ...current };
      for (const item of writes) {
        // The user hand-selected during the test: do not override.
        if (current?.[item]?.source === 'user') continue;
        next[item] = { value: results[item]!.verdict === 'accepted', source: 'tested' };
      }
      return next;
    }, () => { stored = true; });
    // Writing the test result clears the image / toolCall negative cache of the model's first-send transport (i.e. this test's transport).
    clearRelayNegativeCache(
      { connectionId: check.provider.id, modelId: modelID, transport: relayFirstSendTransport(check.provider, check.model) },
      ['image', 'toolCall'],
    );
  } catch (error) {
    // Not yet written to the store: hand to the caller to treat as an interruption; already written: report as written.
    if (!stored) throw error;
    return finish('completed', { written: true, error });
  }
  return finish('completed', { written: true });
}

/** T4 pure computation: clears only tested items; returns undefined if emptied (field omitted). */
export function withoutTestedRelayCapabilityOverrides(
  overrides: RelayCapabilityOverrides | undefined,
): RelayCapabilityOverrides | undefined {
  const next: RelayCapabilityOverrides = {};
  for (const [key, entry] of Object.entries(overrides ?? {})) {
    if (entry && entry.source !== 'tested') (next as Record<string, unknown>)[key] = entry;
  }
  return Object.keys(next).length > 0 ? next : undefined;
}

/** T4: restore auto (clears only tested). After the "restore all to auto" change the production entry uses that; this remains only as a domain function. */
export function restoreRelayAutomaticCapabilities(
  store: StoreApi<AppStore>,
  providerID: string,
  modelID: string,
): boolean {
  const provider = findProvider(store, providerID);
  const model = provider?.models.find((item) => item.id === modelID);
  if (!provider || !model || !hasTestedRelayCapabilityOverrides(model)) return false;
  writeOverrides(store, provider, modelID, withoutTestedRelayCapabilityOverrides);
  return true;
}

/** Update both the enabled list and the same-id catalog entry; other fields and other models are untouched. */
export function writeOverrides(
  store: StoreApi<AppStore>,
  provider: Provider,
  modelID: string,
  update: (current: RelayCapabilityOverrides | undefined) => RelayCapabilityOverrides | undefined,
  onStored?: () => void,
): void {
  const apply = (model: AIModel): AIModel => {
    if (model.id !== modelID) return model;
    const next = { ...model };
    const overrides = update(model.relayCapabilityOverrides);
    if (overrides && Object.keys(overrides).length > 0) next.relayCapabilityOverrides = overrides;
    else delete next.relayCapabilityOverrides;
    return next;
  };
  const models = provider.models.map(apply);
  const catalogModels = provider.catalogModels.map(apply);
  const updatedAt = new Date().toISOString();
  store.getState().updateProvider(provider.id, { models, catalogModels, updatedAt });
  onStored?.();
}
