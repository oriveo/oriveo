/**
 * Text fallback after the upstream rejects a native file block (line level `alwaysWithTextFallback`: the
 * three official protocols on a relay, and the Codex and Grok subscriptions).
 *
 * Whether these lines pass file blocks through varies by site and cannot be known beforehand, so the first
 * attempt sends native blocks under the same rules as a direct connection. When the upstream rejects with
 * 400 / 404 / 413 / 415 / 422 before producing any output, native files that have extracted text are
 * switched to text injection and the request is resent once. After a successful resend the connection
 * (provider id + line) is remembered in memory as not accepting file blocks, so later requests in this page
 * session go straight to text without the extra round trip. If the resend also fails, the user sees the
 * error of the first attempt. For relays the "remember" step instead writes a local negative cache (see below).
 *
 * Only the status code is used; the upstream error text is never parsed.
 */
import {
  type AttachmentTransport,
  NATIVE_FILE_FALLBACK_STATUSES,
} from '@oriveo/core/providers/attachment-transport';
import { classifyRelayCapabilityTestResponse } from '@oriveo/core/providers/relay-capability-test';
import { relayKeyAccessOfEvent } from '../providers/relay-key-access-writeback';
import type { ContentPart, StreamEvent, StreamHandle } from '../providers/types';
import { telemetryProviderKind, trackEvent } from '../telemetry';
import {
  RELAY_NEGATIVE_CACHE_STORAGE_KEY,
  recordRelayNegativeCache,
  type RelayNegativeCacheModelKey,
} from '../chat/relay-negative-cache';
import { safeLocalStorage } from '../../infra/storage/web-storage';
import { recordRelayInputRejectionV2 } from '../capability/input-rejection-flow';
import { INPUT_NEGATIVE_CACHE_STORAGE_KEY, readInputNegativeCache } from '../capability/input-negative-cache';
import { inputNegativeCacheTarget, type InputNegativeCacheTarget } from '../capability/truth/input-truth-adapter';
import { providerFormOf } from '../capability/truth/provider-form';

export type OutboundHistoryMessage = {
  role: 'user' | 'assistant' | 'system';
  content: string | ContentPart[];
};

/*
 * -- This connection rejected file blocks --
 * Relay-form connections record this in the local negative cache under the `file` kind (connection x model x
 * effective protocol, 7 days), and only when the first error is judged a rejection by the "test capability"
 * classifier. Subscription lines still record it per connection x line within this page session.
 */

const rejectedConnections = new Set<string>();

function connectionKey(providerId: string, transport: AttachmentTransport): string {
  return `${providerId}\u0000${transport}`;
}

/**
 * Key of the Relay connection's `file_input` negative cache v2 (the same target the send side writes on
 * rejection); called for relays only (the caller judges the form). Returns null when the protocol family
 * cannot be determined, or when the arguments are not a full connection / model object (production callers
 * always pass full objects).
 */
export function relayFileInputTarget(
  provider: { kind: string; id?: string },
  model: { id: string },
  streamOptions: Parameters<typeof inputNegativeCacheTarget>[2],
): InputNegativeCacheTarget | null {
  if (!isFullProvider(provider) || !isFullModel(model)) return null;
  return inputNegativeCacheTarget(provider, model, streamOptions, 'file_input');
}

/**
 * The `file_input` negative cache v2 target used to read "this connection rejected file blocks": relays and
 * official connections both read v2 (official ones are written on a signature rejection, see
 * `recordOfficialInputRejection`); null when the protocol family cannot be determined (not counted as
 * rejected); undefined for other forms such as subscriptions (read the in-session record).
 */
export function nativeFileInputTarget(
  provider: { kind: string; id?: string; authMode?: string },
  model: { id: string },
  streamOptions: Parameters<typeof inputNegativeCacheTarget>[2],
): InputNegativeCacheTarget | null | undefined {
  if (!provider.id) return undefined;
  const form = providerFormOf(provider as Parameters<typeof providerFormOf>[0]);
  if (form !== 'relay' && form !== 'official') return undefined;
  return relayFileInputTarget(provider, model, streamOptions);
}

type TargetArgs = Parameters<typeof inputNegativeCacheTarget>;

function isFullProvider(provider: { kind: string }): provider is TargetArgs[0] {
  return 'models' in provider;
}

function isFullModel(model: { id: string }): model is TargetArgs[1] {
  return 'name' in model;
}

/**
 * Relays and official connections pass `relayInputTarget` (the `file_input` negative cache v2 target, see
 * `nativeFileInputTarget`; null when the protocol family cannot be determined = not counted as rejected);
 * only v2 is read, while the relay v1 `file` kind is still written alongside but no longer read. On an
 * official hit, native files in history are injected as text instead, per the delivery contract. Other lines
 * pass nothing (undefined) and read this page session's connection x line record.
 */
export function connectionRejectsNativeFiles(
  providerId: string | undefined,
  transport: AttachmentTransport,
  relayInputTarget?: InputNegativeCacheTarget | null,
): boolean {
  if (relayInputTarget !== undefined) {
    return relayInputTarget !== null
      && readInputNegativeCache(relayInputTarget.key, relayInputTarget.verdictRevision) !== null;
  }
  return providerId !== undefined && rejectedConnections.has(connectionKey(providerId, transport));
}

/** Tests only. */
export function __resetNativeFileFallbackForTest(): void {
  rejectedConnections.clear();
  try {
    safeLocalStorage.removeItem(RELAY_NEGATIVE_CACHE_STORAGE_KEY);
    safeLocalStorage.removeItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY);
  } catch { /* noop */ }
}

/* -- Fallback version carried along with the outbound history -- */

interface TextFallback {
  /** The content `buildChatHistory` produces for the same message when the line is treated as `off`. */
  content: string | ContentPart[];
  /** The text of this message (native version) at build time, used to find what is appended to its end later. */
  builtText: string;
  providerId: string;
  providerKind: string;
  transport: AttachmentTransport;
  /** Negative cache key for Relay-form connections; omitted for other lines. */
  relayKey?: RelayNegativeCacheModelKey;
  /** Write target of the Relay-form `file_input` negative cache v2 (written alongside v1); omitted for other lines. */
  relayInputTarget?: InputNegativeCacheTarget;
}

/**
 * The fallback version hangs on a symbol property of the message object: later processing (adding a
 * system prompt, appending text to the end) copies the object by spreading, so it travels along, and
 * `JSON.stringify` never puts it on the wire.
 */
const TEXT_FALLBACK = Symbol('oriveo.attachmentTextFallback');

type Carrier = OutboundHistoryMessage & { [TEXT_FALLBACK]?: TextFallback };

function joinedText(content: string | ContentPart[]): string {
  return typeof content === 'string'
    ? content
    : content.map((part) => (part.type === 'text' ? part.text : '')).join('');
}

function carriesFilePart(content: string | ContentPart[]): boolean {
  return typeof content !== 'string' && content.some((part) => part.type === 'file');
}

/**
 * Attaches the fallback versions one by one to the native history. Both histories are built by the same
 * `buildChatHistory` from the same messages, so they correspond by index.
 */
export function attachTextFallback(
  history: OutboundHistoryMessage[],
  fallbackHistory: OutboundHistoryMessage[],
  connection: {
    providerId: string;
    providerKind: string;
    transport: AttachmentTransport;
    relayKey?: RelayNegativeCacheModelKey;
    relayInputTarget?: InputNegativeCacheTarget;
  },
): void {
  if (history.length !== fallbackHistory.length) return;
  history.forEach((message, index) => {
    if (!carriesFilePart(message.content)) return;
    (message as Carrier)[TEXT_FALLBACK] = {
      content: fallbackHistory[index].content,
      builtText: joinedText(message.content),
      ...connection,
    };
  });
}

interface FallbackPlan {
  history: OutboundHistoryMessage[];
  providerId: string;
  providerKind: string;
  transport: AttachmentTransport;
  relayKey?: RelayNegativeCacheModelKey;
  relayInputTarget?: InputNegativeCacheTarget;
}

/**
 * Derives the fallback version from the current outbound history (after all later processing). If any
 * message carrying a file block does not line up, the fallback is abandoned: better to show the user the
 * first error unchanged than to send a malformed request.
 */
function resolveFallbackPlan(history: OutboundHistoryMessage[]): FallbackPlan | null {
  let connection: Omit<FallbackPlan, 'history'> | null = null;
  const rebuilt: OutboundHistoryMessage[] = [];
  for (const message of history) {
    if (!carriesFilePart(message.content)) {
      rebuilt.push(message);
      continue;
    }
    const fallback = (message as Carrier)[TEXT_FALLBACK];
    if (!fallback) return null;
    // Text appended to the end of this message after the build (library context, the anti-forget reminder) is appended to the fallback version too.
    const current = joinedText(message.content);
    if (!current.startsWith(fallback.builtText)) return null;
    const appended = current.slice(fallback.builtText.length);
    const content = !appended
      ? fallback.content
      : typeof fallback.content === 'string'
        ? `${fallback.content}${appended}`
        : [...fallback.content, { type: 'text' as const, text: appended }];
    rebuilt.push({ role: message.role, content });
    connection = {
      providerId: fallback.providerId,
      providerKind: fallback.providerKind,
      transport: fallback.transport,
      ...(fallback.relayKey ? { relayKey: fallback.relayKey } : {}),
      ...(fallback.relayInputTarget ? { relayInputTarget: fallback.relayInputTarget } : {}),
    };
  }
  return connection ? { history: rebuilt, ...connection } : null;
}

/**
 * The text-fallback version of the whole outbound history (messages carrying file blocks swapped for text
 * injection); null when it does not line up or there is no fallback version. Used when a protocol-level
 * fallback switches to a protocol that does not accept native files, so the new protocol's builder does not
 * reshape the file blocks into something else.
 */
export function textFallbackHistory(history: OutboundHistoryMessage[]): OutboundHistoryMessage[] | null {
  return resolveFallbackPlan(history)?.history ?? null;
}

/* -- Sending -- */

type ErrorEvent = Extract<StreamEvent, { type: 'error' }>;

/** The upstream rejected the request itself (not auth, rate limiting, 5xx or the network, and not a local or own-route rejection). */
function isNativeFileRejection(event: ErrorEvent): boolean {
  if (typeof event.status !== 'number' || !NATIVE_FILE_FALLBACK_STATUSES.has(event.status)) return false;
  return event.source !== 'oriveo' && event.source !== 'network';
}

function isRelayRejection(event: ErrorEvent): boolean {
  return typeof event.status === 'number' && classifyRelayCapabilityTestResponse({
    status: event.status,
    contentType: 'application/json',
    body: event.errorDetail ?? event.error ?? '',
  }) === 'rejected';
}

/** The model has started producing output: later errors no longer fall back. */
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

/**
 * Sends one request; when the outbound history carries a fallback version and the upstream rejects the
 * file blocks before producing output, resends once with the files injected as text. A history without a
 * fallback version (another line, no native files, all scanned) is exactly equivalent to calling `send` directly.
 */
export function sendWithNativeFileFallback<H extends StreamHandle>(
  history: OutboundHistoryMessage[],
  send: (history: OutboundHistoryMessage[]) => H,
): H {
  const primary = send(history);
  const plan = resolveFallbackPlan(history);
  if (!plan) return primary;

  let active: StreamHandle = primary;
  let cancelled = false;

  const stream = new ReadableStream<StreamEvent>({
    async start(ctrl) {
      /**
       * Pipes one stream to the output. An error before output starts goes to `onErrorBeforeOutput` first:
       * returning true means it took over (the error is not forwarded). `onOutput` is called once when the
       * model really starts producing output.
       */
      const pipe = async (
        source: ReadableStream<StreamEvent>,
        onErrorBeforeOutput: (event: ErrorEvent) => Promise<boolean>,
        onOutput?: () => void,
      ): Promise<void> => {
        const reader = source.getReader();
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
            // Side events before output starts (model name, activity state) are held back: if this attempt is rejected they must not show up.
            held.push(value);
          }
        }
        if (!started) begin();
      };

      try {
        await pipe(primary.stream, async (firstError) => {
          if (cancelled || !isNativeFileRejection(firstError)) return false;
          // A key without access to this model is not a file block problem: no text-fallback resend, leave it to the outer layer to record on the model.
          if (plan.relayKey && relayKeyAccessOfEvent(firstError) === 'model_access_denied') return false;
          const retry = send(plan.history);
          active = retry;
          await pipe(
            retry.stream,
            async () => {
              // The resend failed too: it is not a file block problem, so the user sees the first error.
              ctrl.enqueue(firstError);
              return true;
            },
            () => {
              if (plan.relayKey) {
                // Statuses such as 413 that cannot be judged still fall back and resend, but write no negative cache.
                if (isRelayRejection(firstError)) {
                  recordRelayNegativeCache({ ...plan.relayKey, kind: 'file' });
                  recordRelayInputRejectionV2(plan.relayInputTarget);
                }
              } else {
                rejectedConnections.add(connectionKey(plan.providerId, plan.transport));
              }
              // Recorded only after the resend is accepted: just provider_kind and the line name, never the model, file names or status codes.
              trackEvent('native_file_fallback', {
                provider_kind: telemetryProviderKind(plan.providerKind as never),
                protocol: plan.transport,
              });
            },
          );
          return true;
        });
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

  // Other readings on the handle (whether the additional body took effect, and so on) follow the request that is actually running.
  const handle: Record<string, unknown> = { ...(primary as unknown as Record<string, unknown>) };
  for (const [key, value] of Object.entries(primary as unknown as Record<string, unknown>)) {
    if (typeof value === 'function') {
      handle[key] = (...args: unknown[]) => {
        const target = (active as unknown as Record<string, unknown>)[key];
        return typeof target === 'function' ? (target as (...a: unknown[]) => unknown)(...args) : undefined;
      };
    }
  }
  handle.stream = stream;
  handle.abort = () => {
    cancelled = true;
    active.abort();
  };
  return handle as unknown as H;
}
