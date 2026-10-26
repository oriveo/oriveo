/**
 * Data source of the input capability projection: the official ruling, Relay connection evidence,
 * this client's protocol table, wire plain-text-only-ness, Relay overrides and the negative cache are collected into the input of `projectInputCapability`.
 * The vision / file / video entry points and the vision outbound image stripping only read the projection here and no longer judge supported on their own.
 *
 * Covers every form and never returns "no projection". The subscription ruling comes from the subscription truth adapter (first-hand modality > model-facts > unknown),
 * and the protocol family follows the final subscription wire; no overrides.
 *
 * Relay only has connection evidence for vision; file / video rulings are always unknown / catalog_silent.
 * Two kinds of hard block on Relay are projected as "not implemented by this client" and no override can flip them: the connection envelope declares it does not accept that media
 * (image image=false, file nativeFile=false, video video=false); and the connection identity cannot be obtained (a technical failure is not a ruling, fail-closed).
 * Outbound for file / video does not read here (the transport resolver owns it).
 */
import type { AIModel, Provider } from '@oriveo/shared';
import {
  projectInputCapability,
  type InputCapabilityKey,
  type InputCapabilityProjection,
  type InputCapabilityVerdict,
  type InputCapabilityVerdictState,
} from '@oriveo/core/providers/capability-evidence-facade';
import { endImplementsWireFamily } from '@oriveo/core/providers/protocol-implementations';
import { CONTROL_AUTO_AVAILABLE } from '@oriveo/core/providers/request-preference/types';
import { getRelayRuntimeConfig } from '../../metadata/metadata-client';
import { resolveRelayAttachmentSupport } from '../../providers/relay-runtime-support';
import type { StreamOptions } from '../../providers/types';
import {
  effectiveCapabilityTransport,
  relayCapabilityEvidenceIdentity,
  resolveModelCapabilityEvidence,
} from '../../chat/capability-evidence';
import { relayFirstSendTransport, relayUndecidedFirstSendTransport } from '../../providers/relay-first-send-transport';
import { normalizeCapabilityOverrides } from '../capability-overrides';
import { inputVerdictRevision, readInputNegativeCache, type InputNegativeCacheKey } from '../input-negative-cache';
import { currentCapabilityEvidenceModel } from './evidence-model';
import { providerFormOf } from './provider-form';
import { subscriptionInputVerdict } from './subscription-truth-adapter';

export type InputCapabilityProjections = Record<InputCapabilityKey, InputCapabilityProjection>;

const INPUT_KEYS: readonly InputCapabilityKey[] = ['vision_input', 'file_input', 'video_input'];

/**
 * The protocol family each input key uses on the normalized wire (the value of `effectiveCapabilityTransport`);
 * a wire that cannot be recognized, or one with no matching family (for example video on Anthropic / Responses), is treated as not implemented by this client.
 */
const WIRE_FAMILY_BY_TRANSPORT: Readonly<Record<InputCapabilityKey, Readonly<Record<string, string>>>> = {
  vision_input: {
    openai_chat: 'openai_chat.image_url',
    openai_responses: 'openai_responses.input_image',
    anthropic_messages: 'anthropic.image',
    gemini_generate_content: 'gemini.inline_data',
  },
  file_input: {
    openai_chat: 'openai_chat.file',
    openai_responses: 'openai_responses.input_file',
    anthropic_messages: 'anthropic.document',
    gemini_generate_content: 'gemini.inline_data',
  },
  video_input: {
    openai_chat: 'openai_chat.video_url',
    gemini_generate_content: 'gemini.inline_data',
  },
};

/**
 * Wires that can only send plain text: llama.cpp natively folds the whole conversation into a prompt; Gemini Interactions in production only has
 * the pre_activation tier (images are written as placeholders); DashScope native does not send media blocks in this client.
 */
const TEXT_ONLY_TRANSPORTS: ReadonlySet<string> = new Set([
  'llamacpp_native',
  'gemini_interactions',
  'dashscope_native',
]);

/**
 * The normalized wire shared by the projection and the negative cache write target. Relay follows the first-send protocol (the same criterion as the chat first send):
 * when the model protocol is undecided and the first send switches to Messages, Messages is used, so a v2 entry written after a send-side rejection and what the entry point / advanced page / catalog page read are the same protocol family;
 * with no dispatch parameters (entry point, catalog page, advanced page) it also follows the first-send protocol rather than falling to unknown; otherwise it follows the dispatch parameters / decided protocol as before.
 */
function inputTransport(provider: Provider, model: AIModel, streamOptions: StreamOptions | undefined): string {
  const firstSend = providerFormOf(provider) === 'relay'
    ? relayUndecidedFirstSendTransport(provider, model)
      ?? (streamOptions?.relayTransport ? undefined : relayFirstSendTransport(provider, model))
    : undefined;
  return effectiveCapabilityTransport(provider, model, firstSend, streamOptions);
}

type ControlVerdict = NonNullable<AIModel['capabilityControls']>[string] & { wireFamily?: string };

/** Official ruling: capabilityControls[key] is used as the ruling as is, a missing key is null (projected as unknown). */
function officialVerdict(currentModel: AIModel, key: InputCapabilityKey): InputCapabilityVerdict | null {
  const control = currentModel.capabilityControls?.[key] as ControlVerdict | undefined;
  if (!control) return null;
  return {
    // The state is passed to the facade as is: the facade only recognizes auto available / unknown, and every other state is treated as the model lacking it.
    state: control.state as InputCapabilityVerdictState,
    ...(control.reasonCode ? { reasonCode: control.reasonCode } : {}),
    ...(control.wireFamily ? { wireFamily: control.wireFamily } : {}),
    ...(control.sourceRefs ? { sourceRefs: control.sourceRefs } : {}),
  };
}

/** Relay ruling: connection evidence supported -> auto, unsupported -> unavailable, otherwise unknown; the protocol family follows the wire. */
function relayVisionVerdict(
  provider: Provider,
  model: AIModel,
  streamOptions: StreamOptions | undefined,
  lineFamily: string | undefined,
  relayIdentity: ReturnType<typeof relayCapabilityEvidenceIdentity>,
  transport: string,
): InputCapabilityVerdict {
  // Look up the evidence on the same wire as the entry point (the first-send protocol when the protocol is undecided), not on the unknown wire.
  const support = resolveModelCapabilityEvidence({
    key: 'vision_input', provider, model, streamOptions, relayIdentity, effectiveTransport: transport,
  }).support;
  const state: InputCapabilityVerdictState = support === 'supported' ? CONTROL_AUTO_AVAILABLE : support === 'unsupported' ? 'unavailable' : 'unknown';
  return {
    state,
    ...(state === 'unavailable' ? { reasonCode: 'model_capability_absent' } : {}),
    ...(lineFamily ? { wireFamily: lineFamily } : {}),
  };
}

/** Subscription ruling: the subscription truth adapter gives the state, and the protocol family follows the final subscription wire. */
function subscriptionVerdict(
  provider: Provider,
  model: AIModel,
  key: InputCapabilityKey,
  lineFamily: string | undefined,
): InputCapabilityVerdict {
  const { source: _source, ...verdict } = subscriptionInputVerdict(provider, model, key);
  return { ...verdict, ...(lineFamily ? { wireFamily: lineFamily } : {}) };
}

/** Relay file / video: the connection has no evidence for these two keys, so the ruling is always unknown. */
function relaySilentVerdict(lineFamily: string | undefined): InputCapabilityVerdict {
  return { state: 'unknown', reasonCode: 'catalog_silent', ...(lineFamily ? { wireFamily: lineFamily } : {}) };
}

export interface InputCapabilityProjectionOptions {
  /**
   * Whether the Relay connection envelope accepts images / native files; pass it in when the caller already holds the attachment support table. By default it is resolved from the current connection,
   * and an unresolvable envelope (runtime config not loaded) or null does not count as a rejection. The envelope has no video slot, so video_input does not read the envelope.
   */
  relayEnvelopeImage?: boolean | null;
  relayEnvelopeNativeFile?: boolean | null;
}

export function resolveInputCapabilityProjections(
  provider: Provider,
  model: AIModel,
  streamOptions: StreamOptions | undefined,
  options: InputCapabilityProjectionOptions = {},
): InputCapabilityProjections {
  const form = providerFormOf(provider);
  const transport = inputTransport(provider, model, streamOptions);
  const relayIdentity = form === 'relay' ? relayCapabilityEvidenceIdentity(provider, model, streamOptions) : undefined;
  const currentModel = form === 'official' ? currentCapabilityEvidenceModel(provider, model) : model;
  const envelope = form === 'relay' ? relayEnvelope(provider, model, options) : null;

  const verdicts = mapKeys((key) => {
    const lineFamily = WIRE_FAMILY_BY_TRANSPORT[key][transport];
    if (form === 'official') return officialVerdict(currentModel, key);
    if (form === 'subscription') return subscriptionVerdict(provider, model, key, lineFamily);
    return key === 'vision_input'
      ? relayVisionVerdict(provider, model, streamOptions, lineFamily, relayIdentity, transport)
      : relaySilentVerdict(lineFamily);
  });

  const overrides = form === 'relay'
    ? normalizeCapabilityOverrides({
        connection: 'relay',
        legacy: model.relayCapabilityOverrides,
        stored: model.capabilityOverrides,
        serverVerdict: Object.fromEntries(INPUT_KEYS.map((key) => [key, verdicts[key]?.state])),
        now: new Date().toISOString(),
      }).effective
    : null;

  return mapKeys((key) => {
    const verdict = verdicts[key];
    const wireFamily = verdict?.wireFamily ?? WIRE_FAMILY_BY_TRANSPORT[key][transport];
    const relayBlocked = form === 'relay' && (!relayIdentity || envelope?.[key] === false);
    const endImplements = endImplementsWireFamily(wireFamily) && !TEXT_ONLY_TRANSPORTS.has(transport) && !relayBlocked;
    // Only v2 is read: the protocol family is taken from `inputTransport` on both the send-side write and here (Relay follows the first-send protocol); v1 is still written but no longer read.
    const negativeCacheHit = wireFamily !== undefined && readInputNegativeCache(
      { connectionId: provider.id, modelId: model.id, wireFamily, capabilityKey: key },
      inputVerdictRevision(verdict),
    ) !== null;
    const op = overrides?.[key] ?? null;
    return projectInputCapability({
      key,
      verdict,
      endImplements,
      override: op ? { op } : null,
      negativeCacheHit,
      connection: form === 'relay' ? 'relay' : 'official',
    });
  });
}

/** Write target of negative cache v2: the same ruling and protocol family as the read above, so the written entry is hit by the next projection. */
export interface InputNegativeCacheTarget {
  key: InputNegativeCacheKey;
  verdictRevision: string;
}

/**
 * Negative cache write target (key + ruling revision) of an input key on the current wire; only official, Relay and subscription are covered, any other form or an unrecognizable protocol family returns null.
 * The send side writes by it after a rejection, which guarantees it is the same entry that `resolveInputCapabilityProjections` reads.
 */
export function inputNegativeCacheTarget(
  provider: Provider,
  model: AIModel,
  streamOptions: StreamOptions | undefined,
  key: InputCapabilityKey,
): InputNegativeCacheTarget | null {
  const resolved = inputVerdictOf(provider, model, streamOptions, key);
  if (!resolved) return null;
  const { verdict, lineFamily } = resolved;
  const wireFamily = verdict?.wireFamily ?? lineFamily;
  if (wireFamily === undefined) return null;
  return {
    key: { connectionId: provider.id, modelId: model.id, wireFamily, capabilityKey: key },
    verdictRevision: inputVerdictRevision(verdict),
  };
}

function inputVerdictOf(
  provider: Provider,
  model: AIModel,
  streamOptions: StreamOptions | undefined,
  key: InputCapabilityKey,
): { verdict: InputCapabilityVerdict | null; lineFamily: string | undefined } | null {
  const form = providerFormOf(provider);
  if (form !== 'official' && form !== 'relay' && form !== 'subscription') return null;
  const transport = inputTransport(provider, model, streamOptions);
  const lineFamily = WIRE_FAMILY_BY_TRANSPORT[key][transport];
  const verdict = form === 'official'
    ? officialVerdict(currentCapabilityEvidenceModel(provider, model), key)
    : form === 'subscription'
      ? subscriptionVerdict(provider, model, key, lineFamily)
      : key === 'vision_input'
        ? relayVisionVerdict(provider, model, streamOptions, lineFamily, relayCapabilityEvidenceIdentity(provider, model, streamOptions), transport)
        : relaySilentVerdict(lineFamily);
  return { verdict, lineFamily };
}

/** Current ruling state of an input key (a missing ruling = unknown); only official, Relay and subscription are covered, otherwise null. Recorded as baseVerdict when the user sets an override. */
export function inputVerdictState(
  provider: Provider,
  model: AIModel,
  streamOptions: StreamOptions | undefined,
  key: InputCapabilityKey,
): string | null {
  const resolved = inputVerdictOf(provider, model, streamOptions, key);
  return resolved ? resolved.verdict?.state ?? 'unknown' : null;
}

function mapKeys<T>(project: (key: InputCapabilityKey) => T): Record<InputCapabilityKey, T> {
  return {
    vision_input: project('vision_input'),
    file_input: project('file_input'),
    video_input: project('video_input'),
  };
}

/** Whether the Relay connection envelope accepts each key; only false is a rejection, absent / unresolvable does not count; the envelope has no video slot, so video_input is never judged. */
function relayEnvelope(
  provider: Provider,
  model: AIModel,
  options: InputCapabilityProjectionOptions,
): Partial<Record<InputCapabilityKey, boolean | null | undefined>> {
  const needsResolve = options.relayEnvelopeImage === undefined || options.relayEnvelopeNativeFile === undefined;
  const resolved = needsResolve ? resolveRelayAttachmentSupport(provider, getRelayRuntimeConfig(), model) : null;
  return {
    vision_input: options.relayEnvelopeImage !== undefined ? options.relayEnvelopeImage : resolved?.image,
    file_input: options.relayEnvelopeNativeFile !== undefined ? options.relayEnvelopeNativeFile : resolved?.nativeFile,
  };
}
