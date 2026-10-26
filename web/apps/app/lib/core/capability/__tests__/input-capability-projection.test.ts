import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { makeRelayRequested, type AIModel, type Attachment, type Provider } from '@oriveo/shared';
import { TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER } from '@oriveo/core/providers/attachment-transport';
import { inputNegativeCacheTarget, resolveInputCapabilityProjections } from '../truth/input-truth-adapter';
import { recordInputNegativeCache } from '../input-negative-cache';
import { resolveAttachmentCapabilities, withoutUnreceivableImages } from '../../chat/attachment-policy';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../chat/stream-options';
import { createRelayManualModel } from '../../provider-model-ops';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';

// Real metadata rulings recorded from the Server (input_capability_recorded.v1.json): the capabilityControls of the model objects are taken from here as is.
interface RecordedCase { provider: string; model: string; key: string; state: string; reasonCode?: string; wireFamily?: string }
const recorded: RecordedCase[] = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'model-contracts', 'input_capability_recorded.v1.json');
    if (existsSync(candidate)) return (JSON.parse(readFileSync(candidate, 'utf8')) as { cases: RecordedCase[] }).cases;
    dir = path.dirname(dir);
  }
  throw new Error('input_capability_recorded.v1.json not found');
})();

function recordedModel(providerKind: string, modelId: string): AIModel {
  const controls = Object.fromEntries(recorded
    .filter((item) => item.provider === providerKind && item.model === modelId)
    .map(({ key, state, reasonCode, wireFamily }) => [key, {
      state,
      ...(reasonCode ? { reasonCode } : {}),
      ...(wireFamily ? { wireFamily } : {}),
    }]));
  expect(Object.keys(controls)).toContain('vision_input');
  return {
    id: modelId, name: modelId, capabilities: ['text'], transport: 'openai_chat_completions',
    reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '$',
    capabilityControls: controls,
  };
}

function officialProvider(kind: Provider['kind'], model: AIModel): Provider {
  return {
    id: `official-${kind}`, kind, status: { kind: 'connected' }, models: [model], catalogModels: [model],
    apiKey: '', apiKeyPreview: '',
  } as Provider;
}

function relayProvider(model: AIModel, transport: 'openai_chat_completions' | 'llamacpp_native'): Provider {
  const requested = makeRelayRequested('openai_compatible');
  requested.authMode = 'none';
  requested.securityMode = 'local_http';
  requested.transport = transport;
  requested.resolvedAPIBaseURL = 'http://127.0.0.1:8080/v1';
  return {
    id: `relay-${transport}`,
    kind: 'relay',
    status: { kind: 'connected' },
    models: [model],
    catalogModels: [model],
    apiKey: '',
    apiKeyPreview: '',
    baseURLText: 'http://127.0.0.1:8080',
    relayKind: 'openai_compatible',
    relayRequested: requested,
    relayResolvedBaseURLText: 'http://127.0.0.1:8080/v1',
    relayResolvedTransport: transport,
    relayResolvedAuthMode: 'none',
  } as Provider;
}

const image: Attachment = { id: 'img', kind: 'image', fileName: 'cat.png', mimeType: 'image/png', base64Data: 'iVBORw0KGgo=' } as Attachment;
const support = { image: false, nativeFile: false, textFileInline: true };

function outbound(provider: Provider, model: AIModel) {
  const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
  return {
    projection: resolveInputCapabilityProjections(provider, model, options)?.vision_input,
    message: withoutUnreceivableImages([{ text: 'look', attachments: [image] }], provider, model, options)[0]!,
  };
}

describe('input capability projection wired into the vision entry point and outbound image stripping', () => {
  beforeEach(() => resetCapabilityEvidenceIdentitiesForTesting());
  afterEach(() => {
    resetCapabilityEvidenceIdentitiesForTesting();
    localStorage.clear();
  });

  it('DeepSeek flash: ruling auto_available -> entry open, real image sent (no longer ANDed with the connection-level image bit)', () => {
    const model = recordedModel('deepseek', 'deepseek-flash');
    const provider = officialProvider('deepseek', model);
    const { projection, message } = outbound(provider, model);
    expect(projection).toMatchObject({ visible: true, editable: true, outbound: 'native_part' });
    expect(message.attachments).toEqual([image]);
    expect(resolveAttachmentCapabilities(provider, model, support).supportsImage).toBe(true);
  });

  it('DeepSeek v4-pro: model_capability_absent -> entry closed, placeholder written for the DeepSeek wire', () => {
    const model = recordedModel('deepseek', 'deepseek-v4-pro');
    const provider = officialProvider('deepseek', model);
    const { projection, message } = outbound(provider, model);
    expect(projection).toMatchObject({ editable: false, outbound: 'placeholder', disabledReason: 'disabled.model_absent' });
    expect(message.attachments).toBeUndefined();
    expect(message.text).toBe('look\n\n[Image omitted: unsupported by DeepSeek]');
    expect(resolveAttachmentCapabilities(provider, model, { ...support, image: true }).supportsImage).toBe(false);
  });

  it('Relay vision unknown: entry open (first-attach hint), real image sent', () => {
    const model = createRelayManualModel('relay-vision-unknown', true);
    const provider = relayProvider(model, 'openai_chat_completions');
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const { projection, message } = outbound(provider, model);
    expect(projection).toMatchObject({ editable: true, outbound: 'native_part', hint: 'first_attach_once' });
    expect(message.attachments).toEqual([image]);
    expect(resolveAttachmentCapabilities(provider, model, { ...support, image: true }).supportsImage).toBe(true);
    // A connection envelope that does not accept images is a hard block: projected as not implemented by this client.
    const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
    expect(resolveInputCapabilityProjections(provider, model, options, { relayEnvelopeImage: false })?.vision_input)
      .toMatchObject({ editable: false, disabledReason: 'disabled.wire_not_implemented' });
  });

  it('Relay llama.cpp native wire sends plain text only: entry closed, plain-text-wire placeholder written', () => {
    const model = createRelayManualModel('llama-local', true);
    const provider = relayProvider(model, 'llamacpp_native');
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const { projection, message } = outbound(provider, model);
    expect(projection).toMatchObject({ editable: false, outbound: 'placeholder', disabledReason: 'disabled.wire_not_implemented' });
    expect(message.attachments).toBeUndefined();
    expect(message.text).toBe(`look\n\n${TEXT_ONLY_ROUTE_IMAGE_PLACEHOLDER}`);
    expect(resolveAttachmentCapabilities(provider, model, { ...support, image: true }).supportsImage).toBe(false);
  });

  it('DeepSeek flash file: transport_not_supported -> native file entry closed (not implemented by this client), text attachments still accepted', () => {
    const model = recordedModel('deepseek', 'deepseek-flash');
    const provider = officialProvider('deepseek', model);
    const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
    expect(resolveInputCapabilityProjections(provider, model, options)?.file_input)
      .toMatchObject({ visible: false, editable: false, disabledReason: 'disabled.wire_not_implemented' });
    const capabilities = resolveAttachmentCapabilities(provider, model, { ...support, nativeFile: true });
    expect(capabilities).toMatchObject({ supportsNativeFile: false, supportsFile: true });
    expect(capabilities.disabledReasons.file).toBe('disabled.wire_not_implemented');
  });

  it('MiniMax-M3 video: ruling auto_available -> video entry visible and usable', () => {
    const model = recordedModel('miniMax', 'MiniMax-M3');
    const provider = officialProvider('miniMax', model);
    const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
    expect(resolveInputCapabilityProjections(provider, model, options)?.video_input)
      .toMatchObject({ visible: true, editable: true, disabledReason: null });
    expect(resolveAttachmentCapabilities(provider, model, support).supportsVideo).toBe(true);
  });

  it('Relay envelope nativeFile=false: file hard block, a user add override cannot flip it', () => {
    const model = {
      ...createRelayManualModel('relay-file', false),
      relayCapabilityOverrides: { file: { value: true, source: 'user' } },
    } as AIModel;
    const provider = relayProvider(model, 'openai_chat_completions');
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
    expect(resolveInputCapabilityProjections(provider, model, options, { relayEnvelopeNativeFile: true })?.file_input)
      .toMatchObject({ visible: true, editable: true });
    expect(resolveInputCapabilityProjections(provider, model, options, { relayEnvelopeNativeFile: false })?.file_input)
      .toMatchObject({ editable: false, disabledReason: 'disabled.wire_not_implemented' });
    const capabilities = resolveAttachmentCapabilities(provider, model, { ...support, nativeFile: false });
    expect(capabilities.supportsNativeFile).toBe(false);
    expect(capabilities.disabledReasons.file).toBe('disabled.wire_not_implemented');
  });

  it('Relay delta overrides: add beats the v2 negative cache; remove -> disabled.user_removed; legacy-field user choices are normalized per the fixture', () => {
    const base = createRelayManualModel('relay-diff', true);
    const provider = relayProvider(base, 'openai_chat_completions');
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(base, 'automatic', false), base);
    const project = (model: AIModel) => resolveInputCapabilityProjections(provider, model, options, { relayEnvelopeImage: true })?.vision_input;
    const target = inputNegativeCacheTarget(provider, base, options, 'vision_input')!;
    recordInputNegativeCache(target.key, { signatureId: 'test.rejected', verdictRevision: target.verdictRevision });
    expect(project(base)).toMatchObject({ editable: false, disabledReason: 'disabled.rejected_recently' });

    const entry = (op: 'add' | 'remove') => ({ op, setAt: '2026-10-19T00:00:00.000Z', baseVerdict: 'unknown' });
    expect(project({ ...base, capabilityOverrides: { vision_input: entry('add') } }))
      .toMatchObject({ visible: true, editable: true, outbound: 'native_part' });
    expect(project({ ...base, capabilityOverrides: { vision_input: entry('remove') } }))
      .toMatchObject({ editable: false, disabledReason: 'disabled.user_removed' });
    // Stored deltas win over the legacy field; bad entries are dropped one by one, falling back to the user choice in the legacy field.
    expect(project({
      ...base,
      relayCapabilityOverrides: { image: { value: true, source: 'user' } },
      capabilityOverrides: { vision_input: entry('remove') },
    })).toMatchObject({ disabledReason: 'disabled.user_removed' });
    expect(project({
      ...base,
      relayCapabilityOverrides: { image: { value: true, source: 'user' } },
      capabilityOverrides: { vision_input: { op: 'flip', setAt: 'bad', baseVerdict: '' } } as never,
    })).toMatchObject({ visible: true, editable: true });
  });
});
