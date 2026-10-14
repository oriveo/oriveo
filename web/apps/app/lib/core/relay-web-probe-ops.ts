import type { StoreApi } from 'zustand';
import type { AIModel, Provider, RelayCapabilityOverrides } from '@oriveo/shared';
import {
  isRelayWebTransport,
  type RelayWebFragment,
  type RelayWebTransport,
} from '@oriveo/shared/relay/web-fragments';
import type { RelayCapabilityTestReason } from '@oriveo/core/providers/relay-capability-test';
import {
  RELAY_WEB_PROBE_DEADLINE_MS,
  RELAY_WEB_PROBE_MAX_OUTPUT_TOKENS,
  judgeRelayWebProbeResponse,
  relayWebFragmentHash,
  relayWebProbeEvidenceFromBody,
  type RelayWebProbeVerdict,
  relayWebProbeMessages,
  type RelayWebProbeRecord,
  type RelayWebProbeResult,
} from '@oriveo/core/providers/relay-web-probe';
import type { RelayWireRequest } from '@oriveo/core/providers/relay-orchestrator';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import type { StreamOptions } from './providers/types';
import type { AppStore } from './store/app-store';
import { sameNormalizedID } from '../utils/id-utils';
import { buildRelayChatRequest, webRelayTransport } from './providers/adapters/relay';
import { relayFirstSendTransport } from './providers/relay-first-send-transport';
import { canProbeRelayModels, relayProbeConnectionIdentity } from './relay-model-probe-ops';
import {
  relayCapabilityTestStreamOptions,
  sendRelayTestRequestOnce,
  writeOverrides,
  type RelayCapabilityTestSend,
} from './relay-capability-test-ops';
import { relayEffectiveWebFragment } from './chat/relay-web-fragments';
import { writeRelayWebProbeRecord } from './chat/relay-web-probe-records';

/**
 * Relay web probe executor (fixture web-probe.v1.json): RELAY only.
 * The request = same construction as the capability test (the model's first-send protocol) + the fragment stored for that protocol (merged the same way as chat); the only user message is a fixed prompt,
 * streaming, output cap 256, once, total time limit 30 seconds. When that protocol has no stored fragment, the built-in template is probed instead:
 * the template is the effective fragment, so the record and web override are written as usual and no fragment is stored.
 * The result is decided only by evidence parsed by that protocol's production streaming parser; searched / rejected / silent are written to the local record (same hash by merge rules),
 * searched / rejected then write the override web (tested; user source untouched); on silent where the merged result is not searched, tested web is removed; undetermined changes nothing.
 * For automatic triggering see relay-web-probe-auto.ts.
 */

export type RelayWebProbeOutcome = 'completed' | 'unavailable' | 'stopped';
export type RelayWebProbeStopReason = 'cancelled' | 'connection' | 'protocol' | 'fragment' | 'unavailable';

export type RelayWebProbeSource = 'saved' | 'template';

export interface RelayWebProbeRunResult {
  outcome: RelayWebProbeOutcome;
  /** Source of the probed fragment (present only when a request was sent). */
  webSource?: RelayWebProbeSource;
  /** The probed protocol (present only when a request was sent). */
  transport?: RelayWebTransport;
  result?: RelayWebProbeResult;
  reason?: RelayCapabilityTestReason;
  status?: number;
  evidenceUrls: string[];
  /** The merged local record (undetermined / interrupted is not written). */
  record?: RelayWebProbeRecord;
  stopReason?: RelayWebProbeStopReason;
  /** The override web was written to the store. */
  overrideWritten: boolean;
}

function findProvider(store: StoreApi<AppStore>, providerID: string): Provider | undefined {
  return store.getState().providers.find((item) => sameNormalizedID(item.id, providerID));
}

/** The probed protocol: RELAY only, within the per-model probe scope, and the first-choice protocol is one of the four web protocols. */
export function relayWebProbeTransport(provider: Provider, model: AIModel): RelayWebTransport | undefined {
  if (!canProbeRelayModels(provider)) return undefined;
  const transport = relayFirstSendTransport(provider, model);
  return isRelayWebTransport(transport) ? transport : undefined;
}

/** Fragment used by the probe = the effective fragment of the first-send protocol: the stored fragment, or that protocol's built-in template when there is none. */
function relayWebProbeFragment(
  provider: Provider,
  transport: RelayWebTransport,
): { fragment: RelayWebFragment; source: RelayWebProbeSource } {
  return relayEffectiveWebFragment(provider, transport)!;
}

/** Fragment source of the panel web item; undefined = not listed (cannot be probed / first-send protocol undecided). */
export function relayWebProbeSource(provider: Provider, model: AIModel): RelayWebProbeSource | undefined {
  const transport = relayWebProbeTransport(provider, model);
  return transport ? relayWebProbeFragment(provider, transport).source : undefined;
}

/** Chat options for the probe request: same construction as the capability test, with that protocol's fragment and the 256 output cap. */
export function relayWebProbeStreamOptions(provider: Provider, model: AIModel, fragment: RelayWebFragment): StreamOptions {
  return {
    ...relayCapabilityTestStreamOptions(provider, model, 'text'),
    relayWebFragment: fragment,
    relayMaxOutputTokens: RELAY_WEB_PROBE_MAX_OUTPUT_TOKENS,
  };
}

/**
 * Override mirror: tested web reflects only the current merged record; when the snippet changed, or the result is silent and the merged result is not searched, tested web is removed; user source untouched.
 * Returns whether anything was written.
 */
export function dropRelayTestedWebOverride(store: StoreApi<AppStore>, providerID: string, modelID: string): boolean {
  const provider = findProvider(store, providerID);
  const model = provider?.models.find((item) => item.id === modelID);
  if (!provider || model?.relayCapabilityOverrides?.web?.source !== 'tested') return false;
  writeOverrides(store, provider, modelID, (current) => {
    if (current?.web?.source !== 'tested') return current ? { ...current } : current;
    const { web: _web, ...rest } = current;
    return rest;
  });
  return true;
}

export async function runRelayWebProbe(
  store: StoreApi<AppStore>,
  providerID: string,
  modelID: string,
  deps: {
    /** Send that reads the whole body (test double); defaults to the production stream-while-judging send. */
    send?: RelayCapabilityTestSend;
    /** Stream-while-judging send; defaults to the same transport as chat (sendRelayWebProbeStreaming). */
    streamingSend?: RelayWebProbeStreamingSend;
    signal?: AbortSignal;
    /** Total time limit; production = 30 seconds, tests inject a short value. */
    deadlineMs?: number;
    /** Clock (record at). */
    now?: () => number;
  } = {},
): Promise<RelayWebProbeRunResult> {
  const deadlineMs = deps.deadlineMs ?? RELAY_WEB_PROBE_DEADLINE_MS;
  const now = deps.now ?? (() => Date.now());
  const done = (
    outcome: RelayWebProbeOutcome,
    extra: Partial<Omit<RelayWebProbeRunResult, 'outcome'>> = {},
  ): RelayWebProbeRunResult => ({ outcome, evidenceUrls: [], overrideWritten: false, ...extra });

  const provider = findProvider(store, providerID);
  const model = provider?.models.find((item) => item.id === modelID);
  const transport = provider && model ? relayWebProbeTransport(provider, model) : undefined;
  if (!provider || !model || !transport) return done('unavailable');
  const { fragment, source: webSource } = relayWebProbeFragment(provider, transport);
  const fragmentHash = relayWebFragmentHash(fragment);
  const identity = relayProbeConnectionIdentity(provider, modelID);

  let request: RelayWireRequest;
  try {
    request = buildRelayChatRequest(
      resolveProviderAPIKey(provider, model.id),
      model.id,
      relayWebProbeMessages(),
      provider.baseURLText,
      relayWebProbeStreamOptions(provider, model, fragment),
    );
  } catch {
    // Address / security policy rejected: no request was sent, undecidable.
    return done('completed', { transport, webSource, result: 'undetermined', reason: 'network' });
  }

  // An injected whole-body send (test double of the capability test) takes the old path; production defaults to judging while streaming.
  const probed = deps.send
    ? await sendRelayTestRequestOnce(request, deps.send, deps.signal, deadlineMs).then(async (sent) => (sent === 'cancelled'
      ? sent
      : {
        verdict: await judgeRelayWebProbeResponse(transport, typeof sent === 'string' ? { failure: sent } : sent),
        ...(typeof sent === 'string' ? {} : { status: sent.status }),
      }))
    : await probeRelayWebStreaming(request, transport, deps.streamingSend ?? sendRelayWebProbeStreaming, deps.signal, deadlineMs);
  if (probed === 'cancelled') return done('stopped', { transport, webSource, stopReason: 'cancelled' });
  const { verdict } = probed;
  const base = {
    transport,
    webSource,
    result: verdict.result,
    reason: verdict.reason,
    evidenceUrls: verdict.evidenceUrls,
    ...(probed.status !== undefined ? { status: probed.status } : {}),
  };
  // Undecidable: write no record and do not change the override (keep the original value).
  if (verdict.result === 'undetermined') return done('completed', base);

  // Re-check before writing back: cancelled -> not probeable -> connection identity -> protocol -> snippet; stop and write nothing if any changed.
  if (deps.signal?.aborted) return done('stopped', { ...base, stopReason: 'cancelled' });
  const latest = findProvider(store, providerID);
  const latestModel = latest?.models.find((item) => item.id === modelID);
  if (!latest || !latestModel || !relayWebProbeTransport(latest, latestModel)) {
    return done('stopped', { ...base, stopReason: 'unavailable' });
  }
  if (relayProbeConnectionIdentity(latest, modelID) !== identity) return done('stopped', { ...base, stopReason: 'connection' });
  if (relayWebProbeTransport(latest, latestModel) !== transport) return done('stopped', { ...base, stopReason: 'protocol' });
  // Stop when the effective fragment (stored, or the template when there is none) has changed; a different fragment saved by the user during a template probe also counts as changed.
  if (relayWebFragmentHash(relayWebProbeFragment(latest, transport).fragment) !== fragmentHash) {
    return done('stopped', { ...base, stopReason: 'fragment' });
  }

  const record = writeRelayWebProbeRecord(
    { connectionId: latest.id, modelId: modelID, transport },
    { result: verdict.result, source: 'tested', at: new Date(now()).toISOString(), fragmentHash },
  );
  if (verdict.result === 'silent') {
    // If the merged record is still searched (silent does not erase searched), keep tested true; otherwise remove tested web.
    if (record.result !== 'searched') dropRelayTestedWebOverride(store, providerID, modelID);
    return done('completed', { ...base, record });
  }
  if (latestModel.relayCapabilityOverrides?.web?.source === 'user') {
    return done('completed', { ...base, record });
  }
  const value = verdict.result === 'searched';
  writeOverrides(store, latest, modelID, (current): RelayCapabilityOverrides => {
    // The user picked manually during write-back: do not overwrite.
    if (current?.web?.source === 'user') return { ...current };
    return { ...current, web: { value, source: 'tested' } };
  });
  return done('completed', { ...base, record, overrideWritten: true });
}

/* -- Judging while streaming (fixture web-probe.v1.json earlyStopCases) -- */

const SERVER_ERROR_FRAME: RelayWebProbeVerdict = { result: 'undetermined', reason: 'server', evidenceUrls: [] };
/** Server-side errors (overload, internal error, rate limit) cannot show that "this model does not support web search". */
const SERVER_ERROR_TYPES: ReadonlySet<string> = new Set(['overloaded_error', 'api_error', 'server_error', 'rate_limit_error']);

/**
 * Category of the first error frame in the whole SSE body: `{"type":"error","error":{...}}`, an untyped `{"error":...}`, `response.failed`.
 * error.type is a server-side kind -> server, anything else -> rejected; no error frame -> null.
 */
function firstSSEErrorFrame(text: string): 'server' | 'rejected' | null {
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('data:')) continue;
    let payload: unknown;
    try { payload = JSON.parse(trimmed.slice(5).trim()); } catch { continue; }
    if (!payload || typeof payload !== 'object') continue;
    const frame = payload as { type?: unknown; error?: unknown; response?: { error?: unknown } };
    const failed = frame.type === 'response.failed';
    if (frame.type !== 'error' && !failed && frame.error === undefined) continue;
    const error = (failed ? frame.response?.error : frame.error) as { type?: unknown } | undefined;
    const type = error && typeof error === 'object' && typeof error.type === 'string' ? error.type : undefined;
    return !failed && type && SERVER_ERROR_TYPES.has(type) ? 'server' : 'rejected';
  }
  return null;
}

/** Returns as soon as the response headers arrive; the body is left as a stream. */
export type RelayWebProbeStreamingSend = (
  request: RelayWireRequest,
  signal: AbortSignal,
) => Promise<{ status: number; contentType: string | null; body: ReadableStream<Uint8Array> | null }>;

/** Production send: the same transport as chat (the same fetch as sendViaChatTransport); the body is not read to the end. */
export const sendRelayWebProbeStreaming: RelayWebProbeStreamingSend = async (request, signal) => {
  const response = await webRelayTransport.fetch(request.url, {
    method: request.method,
    headers: request.headers,
    body: request.body,
    signal,
  });
  return { status: response.status, contentType: response.headers.get('Content-Type'), body: response.body };
};

/**
 * One web probe request, judged while the 2xx stream arrives: raw bytes are forwarded chunk by chunk to this protocol's production parser; as soon as the parser yields evidence it decides searched
 * and cancels the request; if the stream ends normally the original whole-body judgement applies (rejected / silent / pre-evidence error frames unchanged). A non-SSE or non-2xx response is read in full and judged the original way.
 * The total time limit covers the whole run: reaching it with neither evidence nor an end = undetermined (timeout). External cancellation -> cancelled.
 */
async function probeRelayWebStreaming(
  request: RelayWireRequest,
  transport: RelayWebTransport,
  send: RelayWebProbeStreamingSend,
  signal: AbortSignal | undefined,
  deadlineMs: number,
): Promise<{ verdict: RelayWebProbeVerdict; status?: number } | 'cancelled'> {
  if (signal?.aborted) return 'cancelled';
  const controller = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, deadlineMs);
  const forwardAbort = () => controller.abort();
  signal?.addEventListener('abort', forwardAbort, { once: true });
  const aborted = new Promise<never>((_resolve, reject) => {
    controller.signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
  });
  aborted.catch(() => undefined);
  let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
  let feed: ReadableStreamDefaultController<Uint8Array> | undefined;
  const failure = (): { verdict: RelayWebProbeVerdict } | 'cancelled' => {
    if (signal?.aborted) return 'cancelled';
    return { verdict: { result: 'undetermined', reason: timedOut ? 'timeout' : 'network', evidenceUrls: [] } };
  };
  try {
    let response: Awaited<ReturnType<RelayWebProbeStreamingSend>>;
    try {
      response = await Promise.race([send(request, controller.signal), aborted]);
    } catch {
      return failure();
    }
    const { status, contentType } = response;
    reader = response.body?.getReader();
    // Raw bytes: one copy accumulates into the whole body (judged after the end), the other is fed to the parser chunk by chunk.
    const decoder = new TextDecoder();
    let text = '';
    const parserBody = new ReadableStream<Uint8Array>({ start: (ctrl) => { feed = ctrl; } });
    const pump = (async () => {
      if (!reader) { feed?.close(); return; }
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        text += decoder.decode(value, { stream: true });
        feed?.enqueue(value);
      }
      text += decoder.decode();
      feed?.close();
    })();
    pump.catch(() => undefined);
    const streaming = status >= 200 && status < 300 && (contentType ?? '').toLowerCase().includes('text/event-stream');
    let parserErrored = false;
    try {
      if (streaming) {
        const evidence = await Promise.race([
          relayWebProbeEvidenceFromBody(transport, { status, contentType, body: parserBody }, { stopAtEvidence: true }),
          aborted,
        ]);
        if (evidence.searched) {
          // Evidence seen: decide now, cancel the request, do not wait for the stream to end.
          controller.abort();
          return { verdict: { result: 'searched', reason: 'ok', evidenceUrls: evidence.evidenceUrls }, status };
        }
        parserErrored = evidence.errored;
      }
      await Promise.race([pump, aborted]);
    } catch {
      return failure();
    }
    const verdict = await judgeRelayWebProbeResponse(transport, { status, contentType, body: text });
    // An in-stream error frame before any evidence is classified by error.type: a server-side kind = undetermined (server), anything else = rejected.
    // The frame is recognized from the whole body ourselves: the production Messages parser does not report an error frame as an event.
    // On a streamed 2xx the whole-body judgement can only give rejected for an "error frame before any text"; an error frame after text stays undetermined as before (judge already says so).
    if (streaming && verdict.result === 'rejected' && firstSSEErrorFrame(text) === 'server') {
      return { verdict: SERVER_ERROR_FRAME, status };
    }
    // The parser reported an error frame but the whole-body judgement did not recognize it (unusual frame shape): treat it as a server-side problem and write no record.
    if (streaming && parserErrored && verdict.result === 'silent') return { verdict: SERVER_ERROR_FRAME, status };
    return { verdict, status };
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener('abort', forwardAbort);
    if (reader) void reader.cancel().catch(() => undefined);
    try { feed?.close(); } catch { /* already closed */ }
  }
}
