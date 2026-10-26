/**
 * Official connection upstream rejects media: the first leg fails before any output, the error hits a narrow signature,
 * and the named input key was really carried this time -> write negative cache v2. No retry, the error is untouched;
 * the next projection of that key is `disabled.rejected_recently`, outbound strips the image, and the failure card "resend without images" is just a normal resend.
 * No signature hit, output already started, or a local / network error all have no side effects and the error is shown as is.
 *
 * Official only: Relay has its own rejection loop; subscription has no such negative cache.
 */
import type { AIModel, Provider } from '@oriveo/shared';
import type { InputCapabilityKey } from '@oriveo/core/providers/capability-evidence-facade';
import type { ContentPart, StreamOptions } from '@oriveo/core/providers/types';
import { providerErrorRawBodyOf } from '@oriveo/core/providers/errors';
import { effectiveCapabilityTransport, generationParameterNegativeCacheTarget } from '../chat/capability-evidence';
import { telemetryModelID, telemetryProviderKind, trackEvent } from '../telemetry';
import { recordInputNegativeCache } from './input-negative-cache';
import { matchRejectionSignature } from './rejection-signatures';
import { inputNegativeCacheTarget, type InputNegativeCacheTarget } from './truth/input-truth-adapter';
import { providerFormOf } from './truth/provider-form';

/** Normalized wire -> protocol name in the signature table. */
const SIGNATURE_PROTOCOL_BY_TRANSPORT: Readonly<Record<string, string>> = {
  openai_chat: 'openai_chat',
  openai_responses: 'openai_responses',
  anthropic_messages: 'anthropic',
  gemini_generate_content: 'gemini',
};

const KEY_BY_PART_TYPE: Readonly<Partial<Record<ContentPart['type'], InputCapabilityKey>>> = {
  image_url: 'vision_input',
  file: 'file_input',
  video_url: 'video_input',
};

/** Relay rejections are judged by the "test capabilities" classifier rather than the signature table: v2 entries use this as their signature id. */
export const RELAY_CLASSIFIED_REJECTED_SIGNATURE_ID = 'relay.classified_rejected';

/**
 * When the existing Relay logic writes the v1 `image` / `file` negative cache it also writes a v2 entry (key and revision from `inputNegativeCacheTarget`),
 * so behavior is unchanged after readers switch to v2. Nothing is written when the protocol family cannot be recognized (target is null).
 */
export function recordRelayInputRejectionV2(target: InputNegativeCacheTarget | null | undefined, now?: number): void {
  if (!target) return;
  recordInputNegativeCache(
    target.key,
    { signatureId: RELAY_CLASSIFIED_REJECTED_SIGNATURE_ID, verdictRevision: target.verdictRevision },
    now,
  );
}

export interface InputRejectionResult {
  kind: 'input_rejected';
  capabilityKey: InputCapabilityKey;
  signatureId: string;
  wireFamily: string;
}

/** Parameter signature hit: the parameter the signature names lands in the failed message for "resend without this setting". */
export interface ParamRejectionResult {
  kind: 'param_rejected';
  parameter: string;
  signatureId: string;
}

export type OfficialRejectionResult = InputRejectionResult | ParamRejectionResult;

function carriedKeys(messages: ReadonlyArray<{ content: string | ContentPart[] }>): Set<InputCapabilityKey> {
  const keys = new Set<InputCapabilityKey>();
  for (const message of messages) {
    if (typeof message.content === 'string') continue;
    for (const part of message.content) {
      const key = KEY_BY_PART_TYPE[part.type];
      if (key) keys.add(key);
    }
  }
  return keys;
}

interface FailureFacts {
  status?: unknown;
  source?: unknown;
  streamErrorFrame?: unknown;
  outputStarted?: unknown;
  detail?: unknown;
  message?: unknown;
}

/** Only judged for an upstream response with an HTTP status before any output; in-stream error frames, local / network errors and already-started output do not count. */
function upstreamResponseOf(error: unknown): { status: number; body: string } | null {
  if (!error || typeof error !== 'object') return null;
  const facts = error as FailureFacts;
  if (typeof facts.status !== 'number' || facts.streamErrorFrame === true || facts.outputStarted === true) return null;
  if (facts.source === 'oriveo' || facts.source === 'network') return null;
  const body = providerErrorRawBodyOf(error)
    ?? (typeof facts.detail === 'string' ? facts.detail : undefined)
    ?? (typeof facts.message === 'string' ? facts.message : '');
  return { status: facts.status, body };
}

/**
 * Call after the first leg fails: on a media signature hit write negative cache v2 and return the hit key; on a parameter signature hit record `param:<name>` and return the named parameter;
 * otherwise return null and write nothing.
 * `streamOptions` is the same one used for outbound image stripping (attachment-scoped options), so the written key matches what the next projection reads.
 */
export function recordOfficialInputRejection(input: {
  provider: Provider;
  model: AIModel;
  streamOptions: StreamOptions | undefined;
  messages: ReadonlyArray<{ content: string | ContentPart[] }>;
  error: unknown;
  now?: number;
}): OfficialRejectionResult | null {
  const { provider, model, streamOptions } = input;
  if (providerFormOf(provider) !== 'official') return null;
  const response = upstreamResponseOf(input.error);
  if (!response) return null;
  const carried = carriedKeys(input.messages);
  const protocol = SIGNATURE_PROTOCOL_BY_TRANSPORT[effectiveCapabilityTransport(provider, model, undefined, streamOptions)];
  if (!protocol) return null;
  const targets = new Map([...carried].flatMap((key) => {
    const target = inputNegativeCacheTarget(provider, model, streamOptions, key);
    return target ? [[key, target] as const] : [];
  }));
  const match = matchRejectionSignature({
    protocol,
    wireFamily: [...targets.values()].map((target) => target.key.wireFamily),
    status: response.status,
    body: response.body,
  });
  // Parameter rejected: record `param:<name>` so the next outbound gate omits it; no resend, and the named parameter lands in the failed message for "resend without this setting".
  if (match?.kind === 'param_rejected') {
    const paramTarget = generationParameterNegativeCacheTarget(provider, model, streamOptions, match.parameter);
    if (paramTarget) {
      recordInputNegativeCache(
        paramTarget.key,
        { signatureId: match.signatureId, verdictRevision: paramTarget.verdictRevision },
        input.now,
      );
    }
    return { kind: 'param_rejected', parameter: match.parameter, signatureId: match.signatureId };
  }
  if (!match || match.kind !== 'input_rejected') return null;
  const target = targets.get(match.capabilityKey as InputCapabilityKey);
  if (!target) return null;
  recordInputNegativeCache(
    target.key,
    { signatureId: match.signatureId, verdictRevision: target.verdictRevision },
    input.now,
  );
  trackEvent('input_capability_rejected', {
    provider_kind: telemetryProviderKind(provider.kind),
    model_id: telemetryModelID(provider.kind, model.id),
    capability_key: target.key.capabilityKey,
    signature_id: match.signatureId,
    wire_family: target.key.wireFamily,
  });
  return {
    kind: 'input_rejected',
    capabilityKey: target.key.capabilityKey as InputCapabilityKey,
    signatureId: match.signatureId,
    wireFamily: target.key.wireFamily,
  };
}
