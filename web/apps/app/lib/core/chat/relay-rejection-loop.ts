/**
 * Send side of the Relay upstream rejection loop.
 *
 * - Signal: only a response judged `rejected` by the "test capability" decision function counts, and only before any output; an error frame after output has started fails as usual,
 *   with no resend and no negative cache write.
 * - Image send rejected: the request carries an image and image recognition is unknown at send time -> record `image`, and the failure message shows the "images not supported" notice card.
 * - Protocol-level fallback: a route-level rejection before output (same decision as the per-model probe, `isRelayRouteRejection`), the source is not user,
 *   and this message has not switched yet -> switch to the next protocol among the candidates and resend once; on success write that protocol to the model as observed; on failure report the second error
 *   and record no negative cache. When the connection protocol is user-chosen (not auto), a model without its own protocol does not switch.
 *   The inner layer is the native file fallback (fall back to text on the original protocol first).
 * - Tools: after Relay resends successfully without tools, record `toolCall` (again only when judged rejected), and no longer read or write a false in the old tool memory.
 * - Reasoning tier: a tier was sent, 400 / 422 before output, and the error body names a reasoning parameter -> record `reasoningTier:<tier>`, then resend once on the nearest tier;
 *   if the resend fails again, show the first error. The former xhigh -> high special retry is folded in here (max rejected -> deep).
 *
 * - Key verdict comes before everything above: no access records relayDeniedKeyID and then fails as usual; an invalid key / quota writes the state of that key, the rest as before.
 *
 * - First send of an unverified model (RL2-FIRSTSEND): the first-send protocol is read from `relayFirstSendTransport`; when it differs from effectiveTransport the first send
 *   re-resolves the runtime and goes out with it, and output starting is written to the model as observed; a route-level rejection falls back to another candidate as in the protocol-level fallback above.
 *
 * Only the Relay shape is collected; other shapes are exactly equivalent to calling `send` directly. The negative cache key is the same as the reader's: connection x model x
 * first-send protocol (`relayFirstSendTransport`; for a model that already has a protocol, effectiveTransport) x tier.
 */
import type { StoreApi } from 'zustand';
import type { AIModel, Attachment, Provider, RelayModelTransport, RelayTransportSource } from '@oriveo/shared';
import { decidedTransport, effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { classifyRelayCapabilityTestResponse } from '@oriveo/core/providers/relay-capability-test';
import type { AppStore } from '../store/app-store';
import type { StreamEvent, StreamHandle, StreamOptions } from '../providers/types';
import {
  messagesCarryFilePart,
  nativeFileModeOf,
  relayAttachmentTransport,
} from '@oriveo/core/providers/attachment-transport';
import { type OutboundHistoryMessage, textFallbackHistory } from '../attachments/native-file-fallback';
import { resolveAttachmentLine } from '../attachments/attachment-transport-resolver';
import { providerFormOf } from '../capability/truth/provider-form';
import { isRelayRouteRejection, relayCatalogEndpointTypes, resolveRelayProbeCandidates } from '../providers/relay-probe-candidates';
import { relayFirstSendTransport } from '../providers/relay-first-send-transport';
import { recordRelayTransportObservedAfterFallback } from '../providers/relay-model-observed';
import { applyRelayKeyAccessRejection } from '../providers/relay-key-access-writeback';
import { buildProviderStreamOptions } from './stream-options';
import { presentCapabilityControl } from './capability-control-presentation';
import {
  classifyRelayReasoningTierRejection,
  recordRelayReasoningTierRejection,
  relayReasoningTierFallback,
  relayRejectedReasoningTiers,
} from './relay-reasoning-tiers';
import {
  isRelayNegativeCached,
  recordRelayNegativeCache,
  type RelayNegativeCacheModelKey,
} from './relay-negative-cache';
import {
  recordToolCallSupportFalse,
  toolCallSupportIsRememberedFalse,
  type ToolCallRecoveryIdentity,
  type ToolCallRejectionContext,
} from './capability-recovery-runtime';

type ErrorEvent = Extract<StreamEvent, { type: 'error' }>;

/* -- Signal -- */

/** Whether one HTTP response counts as an "upstream rejection": the same decision function as "test capability". */
export function isRelayRejectionResponse(input: { status: number; contentType?: string | null; body: string }): boolean {
  return classifyRelayCapabilityTestResponse(input) === 'rejected';
}

/**
 * Whether an error event before output counts as an upstream rejection. Only an upstream response carrying an HTTP status is judged: local / own-route / network errors and in-stream error frames
 * (HTTP 200 with the stream already open) do not count.
 */
export function isRelayRejectionEvent(event: ErrorEvent): boolean {
  if (typeof event.status !== 'number' || event.streamErrorFrame) return false;
  if (event.source === 'oriveo' || event.source === 'network') return false;
  return isRelayRejectionResponse({
    status: event.status,
    contentType: 'application/json',
    body: event.errorDetail ?? event.error ?? '',
  });
}

/**
 * Negative cache key of the Relay shape (without tier); returns null for other shapes. Protocol = first-send protocol (chat first send, negative cache reads and writes, and the advanced page all read the same one).
 * `messagesBlockedByFiles` can only be computed on the send side (attachment criterion); a reader of the key does not look at attachments and defaults to false.
 */
export function relayNegativeCacheModelKey(
  provider: Provider,
  model: AIModel,
  options: { messagesBlockedByFiles?: boolean } = {},
): RelayNegativeCacheModelKey | null {
  if (providerFormOf(provider) !== 'relay') return null;
  return { connectionId: provider.id, modelId: model.id, transport: relayFirstSendTransport(provider, model, options) };
}

/**
 * First-send attachment criterion: the attachments of the messages to send contain files, none has extracted text, and the Messages line cannot send native files
 * -> do not change the first send. send / continue compute it from the original attachments and pass it in before entering the loop; whether the Messages line can send native files uses the existing attachment line resolution
 * (file coverage, the `file` negative cache and the protocol envelope are all in it), with no separate criterion.
 */
export async function relayFirstSendMessagesBlockedByFiles(input: {
  provider: Provider;
  model: AIModel;
  messages: ReadonlyArray<{ attachments?: Attachment[] }>;
  streamOptions: StreamOptions | undefined;
}): Promise<boolean> {
  if (providerFormOf(input.provider) !== 'relay') return false;
  const files = input.messages.flatMap((message) => message.attachments ?? []).filter((item) => item.kind === 'file');
  if (files.length === 0) return false;
  if (files.some((file) => !file.extractionErrorCode && Boolean(file.base64Data?.trim()))) return false;
  const messages: RelayModelTransport = 'anthropic_messages';
  const line = await resolveAttachmentLine({
    provider: input.provider,
    model: { ...input.model, relayTransport: messages },
    streamOptions: { ...input.streamOptions, relayTransport: messages },
  });
  return nativeFileModeOf(line) === 'off';
}

/* -- Tools -- */

/** Read "known not to support tools" before sending: Relay looks only at this store (a false in the old tool memory is ignored); other shapes read the old memory. */
export function toolCallRememberedUnsupported(
  provider: Provider,
  model: AIModel,
  identity: ToolCallRecoveryIdentity,
): boolean {
  const key = relayNegativeCacheModelKey(provider, model);
  if (key) return isRelayNegativeCached({ ...key, kind: 'toolCall' });
  return toolCallSupportIsRememberedFalse(identity);
}

/**
 * Connection-level tool memory is written only for connections models.dev does not cover (capability spec D5): the subscription catalog and hand-typed model ids.
 * Catalog models get tool capability from the catalog, a single 4xx writes no memory, and the next send carries tools as usual (fail-open). Relay uses its own negative cache.
 */
function toolCallMemoryEligible(provider: Provider, model: AIModel): boolean {
  return providerFormOf(provider) === 'subscription' || model.isManual === true;
}

/**
 * Called after a successful resend without tools. Relay records `toolCall` only when the first-leg error is judged rejected; subscription / hand-typed models write the old memory; catalog models do not write.
 * The Relay write key follows the protocol actually sent on this path (`sentTransport`, taken from the streamOptions.relayTransport of the outgoing request), not the first-send protocol;
 * defaults to the effective protocol.
 */
export function recordToolCallFallback(
  provider: Provider,
  model: AIModel,
  identity: ToolCallRecoveryIdentity,
  rejection: ToolCallRejectionContext | undefined,
  sentTransport: string | undefined,
  now = Date.now(),
): void {
  const firstSendKey = relayNegativeCacheModelKey(provider, model);
  const key = firstSendKey && { ...firstSendKey, transport: sentTransport ?? effectiveTransport(provider, model) };
  if (!key) {
    if (toolCallMemoryEligible(provider, model)) recordToolCallSupportFalse(identity, now);
    return;
  }
  if (!rejection) return;
  let body: string;
  try {
    body = JSON.stringify(rejection.structuredError) ?? '';
  } catch {
    return;
  }
  if (!isRelayRejectionResponse({ status: rejection.status, contentType: 'application/json', body })) return;
  recordRelayNegativeCache({ ...key, kind: 'toolCall' }, now);
}

/* -- Reasoning tier rejection (fixture reasoning-tier.v1.json) -- */

/** Whether an error event before output is a tier rejection; if so return the rejected tier. Local / network sources and in-stream error frames do not count. */
export function relayReasoningTierRejectionOf(event: ErrorEvent, sentTier: string | undefined): ReturnType<typeof classifyRelayReasoningTierRejection> {
  if (event.streamErrorFrame || event.source === 'oriveo' || event.source === 'network') return null;
  return classifyRelayReasoningTierRejection({
    status: event.status,
    namesReasoning: event.relayReasoningNamed === true,
    sentTier,
    outputStarted: false,
  });
}

/** Options for the tier-landing resend: switch to the nearest tier; when no tier is available send no reasoning field. */
function streamOptionsWithReasoningTier(
  streamOptions: StreamOptions | undefined,
  tier: string | null,
): StreamOptions {
  const { reasoning: _reasoning, capabilityPreferences, ...rest } = streamOptions ?? {};
  const intent = tier === 'fast' ? 'low' : tier;
  return {
    ...rest,
    ...(tier ? { reasoning: tier as NonNullable<StreamOptions['reasoning']> } : {}),
    ...(capabilityPreferences ? {
      capabilityPreferences: {
        web: capabilityPreferences.web,
        ...(intent ? { reasoningIntent: intent as NonNullable<typeof capabilityPreferences.reasoningIntent> } : {}),
      },
    } : {}),
  };
}

/* -- Protocol-level fallback (pure function, fixture protocolFallbackCases) -- */

export function decideRelayProtocolFallback(input: {
  current: RelayModelTransport;
  /** Model protocol source; null when following the connection (the model has no protocol of its own). */
  source: RelayTransportSource | null | undefined;
  candidates: readonly RelayModelTransport[];
  status: number | undefined;
  /** Verbatim upstream response body (for 403, to see whether it carries a registered phrase); treated as empty by default. */
  body?: string | null;
  /** On 2xx, whether it is a web page; defaults to application/json. */
  contentType?: string | null;
  outputStarted: boolean;
  alreadySwitched: boolean;
}): RelayModelTransport | null {
  if (input.outputStarted || input.alreadySwitched || input.source === 'user') return null;
  if (!isRelayRouteRejection({ status: input.status, body: input.body, contentType: input.contentType })) return null;
  return input.candidates.find((candidate) => candidate !== input.current) ?? null;
}

/** The upstream verbatim text left by an error event (allowlisted fragment + message body), for the phrase decision of a route-level rejection. */
function errorEventBody(event: ErrorEvent): string {
  return [event.errorDetail, event.error].filter((part): part is string => typeof part === 'string').join('\n');
}

/* -- Send -- */

export interface RelayRejectionLoopHandle {
  /** This failure is "image send rejected by upstream": the failure message shows the images-not-supported notice card. */
  getRelayImageRejected?: () => boolean;
  /** This failure is "native file block rejected and the fallback chain did not recover": the failure message shows the notice card for unsupported files (if image recognition is also met, image recognition wins). */
  getRelayFileRejected?: () => boolean;
  /** The options used by the last request actually sent (differ from the input after a first-send protocol switch / protocol-level fallback); the passive Relay web search record takes protocol and fragment from it. */
  getRelaySentStreamOptions?: () => StreamOptions | undefined;
}

export interface RelayRejectionLoopInput<H extends StreamHandle> {
  store: StoreApi<AppStore>;
  provider: Provider;
  model: AIModel;
  history: OutboundHistoryMessage[];
  streamOptions: StreamOptions | undefined;
  /** One send (the inner layer includes the native file fallback); on protocol fallback, call it again with stream options for the switched protocol. */
  send: (history: OutboundHistoryMessage[], streamOptions: StreamOptions | undefined) => H;
  /** The candidates for this model; by default the same resolution as the per-model probe. */
  resolveCandidates?: (provider: Provider, model: AIModel) => Promise<RelayModelTransport[]>;
  /**
   * First-send attachment criterion: attachments contain files, none has extracted text, and Messages cannot send native files -> do not change the first send.
   * Computed and passed in by the send side; defaults to false.
   */
  messagesBlockedByFiles?: boolean;
}

function carriesImage(history: readonly OutboundHistoryMessage[]): boolean {
  return history.some((message) => typeof message.content !== 'string'
    && message.content.some((part) => part.type === 'image_url'));
}

function defaultCandidates(provider: Provider, model: AIModel): Promise<RelayModelTransport[]> {
  // The user-chosen connection protocol has the highest priority: a model without its own protocol only follows it and has no other candidates.
  // Existing models that already have their own protocol (reachable / observed) are not bound by this and still fall back by the candidate rules.
  const chosen = decidedTransport(provider, null);
  if (chosen && !model.relayTransport) return Promise.resolve([chosen]);
  return resolveRelayProbeCandidates({
    modelID: model.id,
    supportedEndpointTypes: relayCatalogEndpointTypes(provider.id, model.id),
  });
}

/** Stream options for resending on another protocol: re-resolve the Relay runtime for the new protocol (base URL, profile and identity all follow the protocol). */
function streamOptionsForTransport(
  provider: Provider,
  model: AIModel,
  streamOptions: StreamOptions | undefined,
): StreamOptions | undefined {
  const {
    generationProfile: _generationProfile,
    capabilityIdentity: _capabilityIdentity,
    capabilityRecoveryIdentity: _capabilityRecoveryIdentity,
    ...rest
  } = streamOptions ?? {};
  return buildProviderStreamOptions(provider, rest, model);
}

/**
 * History for resending on another protocol. The history itself is neutral (each protocol builder converts on its own), but native file blocks are produced by the delivery decision of the original protocol:
 * when the new protocol does not accept native files use the text fallback version; with no fallback version do not switch (return null), so the builder does not turn the file block into some other shape.
 */
function historyForTransport(
  history: OutboundHistoryMessage[],
  transport: RelayModelTransport,
): OutboundHistoryMessage[] | null {
  if (!messagesCarryFilePart(history)) return history;
  if (nativeFileModeOf({ transport: relayAttachmentTransport(transport) }) !== 'off') return history;
  return textFallbackHistory(history);
}

/**
 * Whether a rejected image send should record `image`: only when the model has no positive image recognition evidence at any level --
 * no override true, no engine declaration true, and the model capabilities (official inherited or declared) do not include image; undeterminable rejection, output already started, or this message already switched protocol are not recorded.
 */
export function shouldRecordRelayImageRejection(input: {
  provider: Pick<Provider, 'relayRequested'>;
  model: Pick<AIModel, 'capabilities' | 'engineDeclaration' | 'relayCapabilityOverrides'>;
  rejected: boolean;
  outputStarted: boolean;
  protocolSwitched: boolean;
}): boolean {
  if (!input.rejected || input.outputStarted || input.protocolSwitched) return false;
  return relayImageSupportUnknown(input.provider, input.model);
}

/**
 * The model has no positive image recognition evidence at any level: no override true, no engine declaration true, model capabilities do not include image.
 * Whether a rejected image send records `image` and the "unknown" of the model options image card use this same predicate.
 */
export function relayImageSupportUnknown(
  provider: Pick<Provider, 'relayRequested'>,
  model: Pick<AIModel, 'capabilities' | 'engineDeclaration' | 'relayCapabilityOverrides'>,
): boolean {
  if (model.relayCapabilityOverrides?.image?.value === true) return false;
  // An engine declaration counts only on a local engine connection (one with an engineProfile).
  if (provider.relayRequested?.engineProfile && model.engineDeclaration?.image === true) return false;
  return !(model.capabilities ?? []).includes('image');
}

/** Whether the first rejection of a request with a native file block counts as a file rejection signal: 400 / 404 / 415 / 422 before output judged as rejection; 413 does not count. */
const FILE_REJECTION_STATUSES: ReadonlySet<number> = new Set([400, 404, 415, 422]);
function isRelayFileRejectionEvent(event: ErrorEvent): boolean {
  return typeof event.status === 'number' && FILE_REJECTION_STATUSES.has(event.status) && isRelayRejectionEvent(event);
}

/** The model has started output: later errors no longer fall back or record negative cache. */
function isOutput(event: StreamEvent): boolean {
  switch (event.type) {
    case 'delta':
    case 'reasoning':
    case 'image':
    case 'tool_calls':
    case 'tool_call':
    case 'tool_result':
    case 'done':
      return true;
    default:
      return false;
  }
}

export function sendWithRelayRejectionLoop<H extends StreamHandle>(
  input: RelayRejectionLoopInput<H>,
): H & RelayRejectionLoopHandle {
  const { store, provider, model, history } = input;
  let sentStreamOptions = input.streamOptions;
  const send: typeof input.send = (outbound, options) => {
    sentStreamOptions = options;
    return input.send(outbound, options);
  };
  const key = relayNegativeCacheModelKey(provider, model, { messagesBlockedByFiles: input.messagesBlockedByFiles });
  if (!key) return send(history, input.streamOptions);

  // First-send protocol switch for an unverified model (RL2-FIRSTSEND): re-resolve the runtime for the first-send protocol (base URL, profile and web search fragment all follow the protocol).
  const firstSend = key.transport as RelayModelTransport;
  const firstSendSwitched = firstSend !== effectiveTransport(provider, model);
  const primaryHistory = firstSendSwitched ? historyForTransport(history, firstSend) ?? history : history;
  const streamOptions = firstSendSwitched
    ? streamOptionsForTransport(provider, { ...model, relayTransport: firstSend }, input.streamOptions)
    : input.streamOptions;
  // Output started on the first-send protocol: write that protocol to the model as observed (the same write-back as a successful protocol-level fallback).
  const onFirstSendOutput = firstSendSwitched
    ? () => { recordRelayTransportObservedAfterFallback(store, provider, model, firstSend); }
    : undefined;

  const carriesImageNow = carriesImage(history);
  const carriesFileNow = messagesCarryFilePart(history);
  const source = model.relayTransport ? model.relayTransportSource ?? null : null;
  const resolveCandidates = input.resolveCandidates ?? defaultCandidates;

  const primary = send(primaryHistory, streamOptions);
  let active: StreamHandle = primary;
  let cancelled = false;
  let imageRejected = false;
  let fileRejected = false;

  const nextTransport = async (event: ErrorEvent): Promise<RelayModelTransport | null> => {
    // Screen out first with conditions that need no candidates; resolving candidates may require one metadata lookup.
    const body = errorEventBody(event);
    // A 2xx that is a web page is judged by the stream where the response headers are available, and carried along with the event.
    const contentType = event.relayHTMLPage ? 'text/html' : undefined;
    if (source === 'user' || !isRelayRouteRejection({ status: event.status, body, contentType })) return null;
    if (event.source === 'oriveo' || event.source === 'network' || event.streamErrorFrame) return null;
    let candidates: RelayModelTransport[];
    try {
      candidates = await resolveCandidates(provider, model);
    } catch {
      return null;
    }
    return decideRelayProtocolFallback({
      current: key.transport as RelayModelTransport,
      source,
      candidates,
      status: event.status,
      body,
      contentType,
      outputStarted: false,
      alreadySwitched: false,
    });
  };

  const stream = new ReadableStream<StreamEvent>({
    async start(ctrl) {
      const pipe = async (
        sourceStream: ReadableStream<StreamEvent>,
        onErrorBeforeOutput: (event: ErrorEvent) => Promise<boolean>,
        onOutput?: () => void,
      ): Promise<void> => {
        const reader = sourceStream.getReader();
        const held: StreamEvent[] = [];
        let started = false;
        const begin = () => {
          started = true;
          for (const event of held.splice(0)) ctrl.enqueue(event);
        };
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          if (started) {
            ctrl.enqueue(value);
          } else if (value.type === 'error') {
            if (await onErrorBeforeOutput(value)) return;
            begin();
            ctrl.enqueue(value);
          } else if (isOutput(value)) {
            onOutput?.();
            begin();
            ctrl.enqueue(value);
          } else {
            // Side-channel events before output are held back: if this attempt is replaced, they must not appear.
            held.push(value);
          }
        }
        if (!started) begin();
      };

      try {
        await pipe(primary.stream, async (firstError) => {
          if (cancelled) return false;
          // First decide "this key cannot use this model": no access is recorded only on the model, with no negative cache write, no protocol switch and no resend with another key.
          if (applyRelayKeyAccessRejection(store, provider, model, firstError) === 'model_access_denied') return false;
          // Reasoning tier rejected: record that tier and resend once on the nearest tier; if the resend fails again, show this (first) error.
          const rejectedTier = relayReasoningTierRejectionOf(firstError, streamOptions?.reasoning);
          if (rejectedTier && !cancelled) {
            recordRelayReasoningTierRejection(key, rejectedTier);
            const available = presentCapabilityControl(provider, model, 'reasoning').availableIntents
              .map((intent) => (intent === 'low' ? 'fast' : intent));
            const fallback = relayReasoningTierFallback(available, relayRejectedReasoningTiers(key), rejectedTier);
            const retry = send(primaryHistory, streamOptionsWithReasoningTier(streamOptions, fallback));
            active = retry;
            await pipe(retry.stream, async (retryError) => {
              applyRelayKeyAccessRejection(store, provider, model, retryError);
              ctrl.enqueue(firstError);
              return true;
            }, onFirstSendOutput);
            return true;
          }
          // If the inner text fallback did not recover (or all are scans that cannot fall back), what arrives here is the error of the request that carried the file block.
          const fileRejectionSignal = carriesFileNow && isRelayFileRejectionEvent(firstError);
          const next = await nextTransport(firstError);
          const retryHistory = next ? historyForTransport(history, next) : null;
          if (next && retryHistory && !cancelled) {
            const switchedModel: AIModel = { ...model, relayTransport: next };
            const retry = send(retryHistory, streamOptionsForTransport(provider, switchedModel, input.streamOptions));
            active = retry;
            // Still failing after switching: report the second error (forward as usual), no further switch, no value written, no negative cache recorded.
            await pipe(retry.stream, async (retryError) => {
              applyRelayKeyAccessRejection(store, provider, model, retryError);
              fileRejected = fileRejectionSignal;
              return false;
            }, () => {
              recordRelayTransportObservedAfterFallback(store, provider, model, next);
            });
            return true;
          }
          // Reaching here means no output yet and this message has not switched protocol (if it had, it would already have been taken over above).
          if (carriesImageNow && shouldRecordRelayImageRejection({
            provider,
            model,
            rejected: isRelayRejectionEvent(firstError),
            outputStarted: false,
            protocolSwitched: false,
          })) {
            recordRelayNegativeCache({ ...key, kind: 'image' });
            imageRejected = true;
          }
          // When one message meets both image rejection and file rejection, the image card wins.
          fileRejected = fileRejectionSignal && !imageRejected;
          return false;
        }, onFirstSendOutput);
        ctrl.close();
      } catch (error) {
        ctrl.error(error);
      }
    },
    cancel() {
      cancelled = true;
      active.abort();
    },
  });

  // Other readings on the handle follow the request actually running.
  const handle: Record<string, unknown> = { ...(primary as unknown as Record<string, unknown>) };
  for (const [name, value] of Object.entries(primary as unknown as Record<string, unknown>)) {
    if (typeof value === 'function') {
      handle[name] = (...args: unknown[]) => {
        const target = (active as unknown as Record<string, unknown>)[name];
        return typeof target === 'function' ? (target as (...a: unknown[]) => unknown)(...args) : undefined;
      };
    }
  }
  handle.stream = stream;
  handle.abort = () => {
    cancelled = true;
    active.abort();
  };
  handle.getRelayImageRejected = () => imageRejected;
  handle.getRelayFileRejected = () => fileRejected;
  handle.getRelaySentStreamOptions = () => sentStreamOptions;
  return handle as unknown as H & RelayRejectionLoopHandle;
}
