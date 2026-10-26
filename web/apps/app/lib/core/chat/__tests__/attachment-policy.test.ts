import { describe, it, expect } from 'vitest';
import { makeRelayRequested, type AIModel, type Attachment, type AttachmentKind, type Provider } from '@oriveo/shared';
import type { ProviderAttachmentSupport } from '../../metadata/metadata-client';
import { relayCapabilityEvidenceIdentity } from '../capability-evidence';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../stream-options';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';
import { TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER, attachmentTransportProfile } from '@oriveo/core/providers/attachment-transport';
import {
  resolveAttachmentCapabilities,
  resolveProviderAttachmentSupport,
  canAcceptDroppedAttachment,
  buildAcceptAttribute,
  filterCurrentTurnAttachments,
} from '../attachment-policy';

function makeModel(capabilities: string[]): AIModel {
  return {
    id: 'm',
    name: 'M',
    capabilities,
    transport: 'openai_chat_completions',
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '$',
  };
}

/** Server vision verdict (capabilityControls.vision_input); omitted = the verdict is absent, projected as unknown. */
function withVision(model: AIModel, state: 'auto_available' | 'unavailable'): AIModel {
  return {
    ...model,
    capabilityControls: {
      vision_input: state === 'unavailable'
        ? { state, reasonCode: 'model_capability_absent', wireFamily: 'openai_chat.image_url' }
        : { state, wireFamily: 'openai_chat.image_url' },
    } as AIModel['capabilityControls'],
  };
}

/** Add the Server verdict for one input key to a model (other existing keys are kept). */
function withInput(
  model: AIModel,
  key: 'file_input' | 'video_input',
  state: 'auto_available' | 'unavailable',
): AIModel {
  const wireFamily = key === 'file_input' ? 'openai_chat.file' : 'openai_chat.video_url';
  return {
    ...model,
    capabilityControls: {
      ...model.capabilityControls,
      [key]: state === 'unavailable'
        ? { state, reasonCode: 'model_capability_absent', wireFamily }
        : { state, wireFamily },
    } as AIModel['capabilityControls'],
  };
}

/** A model whose vision verdict is unavailable: the entry is off and images are not sent. */
function makeTextOnlyModel(capabilities: string[]): AIModel {
  return withVision(makeModel(capabilities), 'unavailable');
}

function makeProvider(): Provider {
  return {
    id: 'provider', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [],
    apiKey: '', apiKeyPreview: '',
  } as Provider;
}

const provider = makeProvider();

function makeSupport(p: Partial<ProviderAttachmentSupport>): ProviderAttachmentSupport {
  return { image: false, nativeFile: false, textFileInline: false, ...p };
}

function makeAttachment(kind: AttachmentKind): Attachment {
  return { id: 'a', kind, fileName: 'f.bin', mimeType: 'application/octet-stream' };
}

describe('resolveAttachmentCapabilities', () => {
  it('image only reads the input capability projection (official providers use capabilityControls.vision_input) and is no longer ANDed with provider.image', () => {
    const auto = withVision(makeModel(['text']), 'auto_available');
    expect(resolveAttachmentCapabilities(provider, auto, makeSupport({ image: true })).supportsImage).toBe(true);
    expect(resolveAttachmentCapabilities(provider, auto, makeSupport({ image: false })).supportsImage).toBe(true);
    // Verdict unavailable: an old "image" entry in capabilities no longer counts.
    expect(
      resolveAttachmentCapabilities(provider, makeTextOnlyModel(['image']), makeSupport({ image: true })).supportsImage,
    ).toBe(false);
    // Verdict absent = unknown: the entry stays open (the projection supplies the first-attach hint).
    expect(
      resolveAttachmentCapabilities(provider, makeModel(['text']), makeSupport({ image: false })).supportsImage,
    ).toBe(true);
  });

  it('official vision only trusts the capabilityControls verdict: neither the vision candidate nor the legacy image bit takes part', () => {
    const model: AIModel = {
      ...makeTextOnlyModel(['image']),
      capabilityEvidenceCandidates: [{
        key: 'vision_input', support: 'unsupported', source: 'server_profile', grade: 'declared',
        scope: 'provider_model_transport', providerKind: 'openAI', modelId: 'm',
        transport: 'openai_chat',
      }],
    };
    expect(resolveAttachmentCapabilities(provider, model, makeSupport({ image: true })).supportsImage).toBe(false);
    const auto: AIModel = { ...withVision(model, 'auto_available') };
    expect(resolveAttachmentCapabilities(provider, auto, makeSupport({ image: true })).supportsImage).toBe(true);
  });

  it('the generation evidence namespace does not withdraw the legacy vision fact before it publishes vision', () => {
    const model: AIModel = {
      ...makeModel(['image']),
      capabilityEvidenceCandidates: [{
        key: 'generation_parameter/temperature', support: 'supported', source: 'server_profile', grade: 'declared',
        scope: 'provider_model_transport', providerKind: 'openAI', modelId: 'm',
        transport: 'openai_chat_completions',
      }],
    };
    expect(resolveAttachmentCapabilities(provider, model, makeSupport({ image: true })).supportsImage).toBe(true);
  });

  it('does not retain an old provider identity after a connection switch', () => {
    const model = makeTextOnlyModel(['image']);
    const first = { ...provider, kind: 'openAI' } as Provider;
    const second = { ...provider, id: 'relay-2', kind: 'relay', relayResolvedTransport: 'openai_chat_completions' } as Provider;
    expect(resolveAttachmentCapabilities(first, model, makeSupport({ image: true })).supportsImage).toBe(false);
    // A relay does not borrow the official verdict; without a local identity this connection fails closed.
    expect(resolveAttachmentCapabilities(second, makeModel(['image']), makeSupport({ image: true })).supportsImage).toBe(false);
  });

  it('a relay connection with transport auto and a model that declares vision: the envelope is looked up by the effective transport, an evidence identity is built, and the entry is editable', () => {
    resetCapabilityEvidenceIdentitiesForTesting();
    const requested = makeRelayRequested('openai_compatible');
    requested.transport = 'auto';
    requested.authMode = 'bearer';
    const model: AIModel = { ...withVision(makeModel(['text', 'image']), 'auto_available'), transport: undefined };
    const relay = {
      id: 'relay-auto', kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [model],
      apiKey: 'sk-relay-test', apiKeyPreview: 'sk-r…test', baseURLText: 'https://api.myrelay.dev',
      relayKind: 'openai_compatible', relayRequested: requested,
    } as Provider;
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), relay.id);
    const streamOptions = buildProviderStreamOptions(relay, buildStreamOptionsFromIntent(model, 'automatic', false), model);
    expect(relayCapabilityEvidenceIdentity(relay, model, streamOptions)).toBeDefined();
    const capabilities = resolveAttachmentCapabilities(relay, model, resolveProviderAttachmentSupport(relay, model));
    expect(capabilities.supportsImage).toBe(true);
    expect(capabilities.projections.image?.editable).toBe(true);
    resetCapabilityEvidenceIdentitiesForTesting();
  });

  it('video: official providers only read the video_input projection (a missing key = unknown, left open), no longer looking at model.capabilities or provider.video', () => {
    const unknown = resolveAttachmentCapabilities(provider, makeModel([]), makeSupport({}));
    expect(unknown.supportsVideo).toBe(true);
    expect(unknown.projections.video?.hint).toBe('first_attach_once');
    expect(
      resolveAttachmentCapabilities(provider, withInput(makeModel([]), 'video_input', 'auto_available'), makeSupport({})).supportsVideo,
    ).toBe(true);
    const absent = resolveAttachmentCapabilities(
      provider, withInput(makeModel(['video']), 'video_input', 'unavailable'), makeSupport({}),
    );
    expect(absent.supportsVideo).toBe(false);
    expect(absent.disabledReasons.video).toBe('disabled.model_absent');
  });

  it('file: text-like files look at textFileInline; native files (PDF) only read the file_input projection', () => {
    const absentFile = withInput(makeModel([]), 'file_input', 'unavailable');
    const textOnly = resolveAttachmentCapabilities(provider, absentFile, makeSupport({ textFileInline: true, nativeFile: true }));
    expect(textOnly).toMatchObject({ supportsFile: true, supportsNativeFile: false });
    expect(textOnly.disabledReasons.file).toBe('disabled.model_absent');
    // Verdict absent = unknown: the native-file entry stays open, regardless of the connection-level nativeFile bit.
    expect(resolveAttachmentCapabilities(provider, makeModel([]), makeSupport({}))).toMatchObject({
      supportsFile: true, supportsNativeFile: true,
    });
    expect(resolveAttachmentCapabilities(provider, absentFile, makeSupport({})).supportsFile).toBe(false);
  });

  it('supportsAttachment is the union of the three', () => {
    expect(
      resolveAttachmentCapabilities(provider, makeModel(['image']), makeSupport({ image: true })).supportsAttachment,
    ).toBe(true);
    expect(
      resolveAttachmentCapabilities(provider, makeModel([]), makeSupport({ textFileInline: true })).supportsAttachment,
    ).toBe(true);
    const nothing = withInput(withInput(makeTextOnlyModel([]), 'file_input', 'unavailable'), 'video_input', 'unavailable');
    expect(resolveAttachmentCapabilities(provider, nothing, makeSupport({})).supportsAttachment).toBe(false);
  });

  it('everything is false when model and provider are null, with the reason being that the model lacks the capability', () => {
    expect(resolveAttachmentCapabilities(null, null, null)).toEqual({
      supportsImage: false,
      supportsVideo: false,
      supportsFile: false,
      supportsNativeFile: false,
      supportsAttachment: false,
      disabledReasons: { image: 'disabled.model_absent', file: 'disabled.model_absent', video: 'disabled.model_absent' },
      projections: { image: null, file: null, video: null },
    });
  });
});

describe('canAcceptDroppedAttachment', () => {
  const model = makeModel(['image']);

  it('an image attachment is judged by the image capability', () => {
    expect(canAcceptDroppedAttachment(makeAttachment('image'), provider, model, makeSupport({ image: true }))).toBe(true);
    expect(
      canAcceptDroppedAttachment(makeAttachment('image'), provider, makeTextOnlyModel(['image']), makeSupport({ image: true })),
    ).toBe(false);
  });

  it('a text-like file is judged by the file capability (either text inlining or native files)', () => {
    const absentFile = withInput(model, 'file_input', 'unavailable');
    expect(
      canAcceptDroppedAttachment(makeAttachment('file'), provider, absentFile, makeSupport({ textFileInline: true })),
    ).toBe(true);
    expect(canAcceptDroppedAttachment(makeAttachment('file'), provider, absentFile, makeSupport({}))).toBe(false);
  });

  it('a PDF only looks at the file_input projection: it is rejected even when text inlining is on', () => {
    const pdf = { ...makeAttachment('file'), fileName: 'a.pdf', mimeType: 'application/pdf' };
    const absentFile = withInput(model, 'file_input', 'unavailable');
    expect(canAcceptDroppedAttachment(pdf, provider, absentFile, makeSupport({ textFileInline: true }))).toBe(false);
    expect(
      canAcceptDroppedAttachment(pdf, provider, withInput(model, 'file_input', 'auto_available'), makeSupport({})),
    ).toBe(true);
  });

  it('a video attachment reads the video_input projection and no longer borrows the file capability', () => {
    const absentVideo = withInput(makeModel(['video']), 'video_input', 'unavailable');
    expect(
      canAcceptDroppedAttachment(makeAttachment('video'), provider, absentVideo, makeSupport({ textFileInline: true })),
    ).toBe(false);
    expect(
      canAcceptDroppedAttachment(
        makeAttachment('video'), provider, withInput(makeModel([]), 'video_input', 'auto_available'), makeSupport({}),
      ),
    ).toBe(true);
  });
});

describe('buildAcceptAttribute', () => {
  it('image support alone yields image/*', () => {
    const model = withInput(makeModel(['image']), 'file_input', 'unavailable');
    expect(buildAcceptAttribute(provider, model, makeSupport({ image: true }))).toBe('image/*');
  });

  it('image plus nativeFile yields image/* first, then .pdf and .docx', () => {
    const accept = buildAcceptAttribute(provider, makeModel(['image']), makeSupport({ image: true, nativeFile: true }));
    expect(accept.startsWith('image/*,')).toBe(true);
    expect(accept).toContain('.pdf');
    expect(accept).toContain('.docx');
  });

  it('textFileInline with the native-file verdict unavailable yields text extensions but neither image/* nor .pdf', () => {
    const model = withInput(makeTextOnlyModel([]), 'file_input', 'unavailable');
    const accept = buildAcceptAttribute(provider, model, makeSupport({ textFileInline: true }));
    expect(accept).not.toContain('image/*');
    expect(accept).not.toContain('.pdf');
    expect(accept).toContain('.txt');
  });
});

// A retry or an edited resend carries the original message's attachments; they go through the current model's capabilities once more before sending.
describe('filterCurrentTurnAttachments', () => {
  const image = { ...makeAttachment('image'), id: 'img' };
  const video = { ...makeAttachment('video'), id: 'vid' };
  const file = { ...makeAttachment('file'), id: 'doc' };
  const history = { id: 'old', attachments: [image, video, file] };
  const turn = { id: 'now', attachments: [image, video, file] };

  it('keeps only the kinds the current model accepts; earlier history is untouched', () => {
    const out = filterCurrentTurnAttachments(
      [history, turn], 'now', provider, withInput(makeTextOnlyModel(['text']), 'video_input', 'unavailable'),
      makeSupport({ image: true, textFileInline: true }),
    );
    // Both the vision and video verdicts are unavailable: only files remain
    expect(out[1].attachments).toEqual([file]);
    expect(out[0]).toBe(history);
  });

  it('files depend on whether the connection accepts files', () => {
    const out = filterCurrentTurnAttachments(
      [turn], 'now', provider, withInput(makeModel(['text', 'image']), 'video_input', 'unavailable'), makeSupport({ image: true }),
    );
    expect(out[0].attachments).toEqual([image]);
  });

  it('video reads the video_input projection outbound: with the projection at native_part and the legacy video bit false, the video is kept', () => {
    for (const model of [makeModel(['text']), withInput(makeModel(['text']), 'video_input', 'auto_available')]) {
      expect(resolveAttachmentCapabilities(provider, model, makeSupport({})).projections.video?.outbound).toBe('native_part');
      const out = filterCurrentTurnAttachments([turn], 'now', provider, model, makeSupport({ image: true }));
      expect(out[0].attachments).toEqual([image, video]);
    }
  });

  it('video projection placeholder: the video is dropped and a one-line placeholder is left (even a true legacy video bit does not keep the video block)', () => {
    const model = withInput(makeModel(['text', 'video']), 'video_input', 'unavailable');
    const support = makeSupport({ image: true, textFileInline: true });
    expect(resolveAttachmentCapabilities(provider, model, support).projections.video?.outbound).toBe('placeholder');
    const out = filterCurrentTurnAttachments([{ ...turn, text: 'look' }], 'now', provider, model, support);
    expect(out[0].attachments).toEqual([image, file]);
    const placeholder = attachmentTransportProfile('openai_chat').videoPlaceholderText ?? TEXT_ONLY_ROUTE_VIDEO_PLACEHOLDER;
    expect(out[0].text).toBe(`look\n\n${placeholder}`);
    expect(out[0].text).not.toContain(video.fileName);
    expect((out[0] as { omittedImagePlaceholders?: string[] }).omittedImagePlaceholders).toEqual([placeholder]);
  });

  it('support table not loaded yet (null): unknown is not unsupported, returned as is', () => {
    const messages = [turn];
    expect(filterCurrentTurnAttachments(messages, 'now', provider, makeModel(['text']), null)).toBe(messages);
  });

  it('attachments are cleared when none is accepted; the same array is returned unchanged when all are accepted', () => {
    expect(filterCurrentTurnAttachments(
      [turn], 'now', provider, withInput(makeTextOnlyModel(['text']), 'video_input', 'unavailable'), makeSupport({}),
    )[0].attachments).toBeUndefined();

    const messages = [{ id: 'now', attachments: [file] }];
    expect(filterCurrentTurnAttachments(
      messages, 'now', provider, makeModel(['text']), makeSupport({ textFileInline: true }),
    )).toBe(messages);
  });
});
