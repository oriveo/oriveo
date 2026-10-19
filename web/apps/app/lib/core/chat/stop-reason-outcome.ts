/**
 * The stopReason persisted when an assistant message finishes.
 * It only records one extra column: the message state and the UI are still decided by each finishing path, and this takes no part in that.
 */
import type { ProviderKind } from '@oriveo/shared';
import { StopReasonResolver, type StopFamily, type StopReason } from '@oriveo/core/context/stop-reason';
import type { StreamFinish } from '@oriveo/core/context/stream-finish';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { officialWireProtocol } from '@oriveo/core/providers/request-builders/official-protocol';
import { getPublicProviderConfig } from '../metadata/metadata-client';

/** Protocol family assigned when no finish is available at finishing time (error path); the non-clean decision is independent of the family and this only satisfies the signature. */
export function stopFamilyForProvider(kind: ProviderKind): StopFamily {
  return 'openai_chat';
}

/**
 * Protocol family of the wire protocol this request actually used: a relay goes by its outbound protocol (Anthropic protocol -> anthropic);
 * official vendors follow the same rules as dispatch (metadata apiProtocol reroutes, otherwise the native protocol);
 * when it still cannot be recognized (the openai native family and the like), fall back to the connection kind.
 */
export function stopFamilyForRequest(kind: ProviderKind, relayTransport: StreamOptions['relayTransport']): StopFamily {
  switch (relayTransport) {
    case 'anthropic_messages': return 'anthropic';
    case 'openai_responses': return 'openai_responses';
    case 'gemini_generate_content': return 'gemini';
    case 'openai_chat_completions': return 'openai_chat';
    default: {
      const apiProtocol = getPublicProviderConfig(kind)?.apiProtocol;
      const official = officialWireProtocol(kind, apiProtocol);
      return official ? stopFamilyForRequest(kind, official) : stopFamilyForProvider(kind);
    }
  }
}

/** Stream read to the end normally (done): judged by the finish on done; recorded as unknown when the protocol family is unrecognized or done carries no finish. */
export function stopReasonFromFinish(finish: StreamFinish | undefined, hadContent: boolean): StopReason {
  if (!finish) return 'unknown';
  return StopReasonResolver.resolve(finish.family, finish.ended, finish.finishRaw, hadContent);
}

/**
 * Stream threw: a finish on the error (a terminating frame that throws) decides it;
 * otherwise it is judged by the in-stream error frame / transport-layer error, and hadContent decides between incomplete and error.
 */
export function stopReasonFromError(error: unknown, kind: ProviderKind, hadContent: boolean): StopReason {
  const record = error && typeof error === 'object' ? error as { finish?: unknown; streamErrorFrame?: unknown } : undefined;
  const finish = record?.finish;
  if (isStreamFinish(finish)) {
    return StopReasonResolver.resolve(finish.family, finish.ended, finish.finishRaw, hadContent);
  }
  const ended = record?.streamErrorFrame === true ? 'error_frame' : 'transport_error';
  return StopReasonResolver.resolve(stopFamilyForProvider(kind), ended, undefined, hadContent);
}

function isStreamFinish(value: unknown): value is StreamFinish {
  return Boolean(value && typeof value === 'object'
    && typeof (value as { family?: unknown }).family === 'string'
    && typeof (value as { ended?: unknown }).ended === 'string');
}
