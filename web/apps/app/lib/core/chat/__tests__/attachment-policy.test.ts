import { describe, it, expect } from 'vitest';
import type { AIModel, Attachment, AttachmentKind, Provider } from '@oriveo/shared';
import type { ProviderAttachmentSupport } from '../../metadata/metadata-client';
import {
  resolveAttachmentCapabilities,
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
  it('image requires the image capability on the model and image support on the provider', () => {
    expect(
      resolveAttachmentCapabilities(provider, makeModel(['image']), makeSupport({ image: true })).supportsImage,
    ).toBe(true);
    expect(
      resolveAttachmentCapabilities(provider, makeModel(['image']), makeSupport({ image: false })).supportsImage,
    ).toBe(false);
    expect(
      resolveAttachmentCapabilities(provider, makeModel(['text']), makeSupport({ image: true })).supportsImage,
    ).toBe(false);
  });

  it('production metadata candidate passes through facade and overrides legacy image bit', () => {
    const model: AIModel = {
      ...makeModel(['image']),
      capabilityEvidenceCandidates: [{
        key: 'vision_input', support: 'unsupported', source: 'server_profile', grade: 'declared',
        scope: 'provider_model_transport', providerKind: 'openAI', modelId: 'm',
        transport: 'openai_chat',
      }],
    };
    expect(resolveAttachmentCapabilities(provider, model, makeSupport({ image: true })).supportsImage).toBe(false);
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
    const model = makeModel(['image']);
    const first = { ...provider, kind: 'openAI' } as Provider;
    const second = { ...provider, id: 'relay-2', kind: 'relay', relayResolvedTransport: 'openai_chat_completions' } as Provider;
    expect(resolveAttachmentCapabilities(first, model, makeSupport({ image: true })).supportsImage).toBe(true);
    // Relay has no complete opaque identity in this unit's production input,
    // so its connection-scoped legacy fact must fail closed rather than borrow
    // the previous official-provider result.
    expect(resolveAttachmentCapabilities(second, model, makeSupport({ image: true })).supportsImage).toBe(false);
  });

  it('video requires the video capability on the model and video support on the provider', () => {
    expect(
      resolveAttachmentCapabilities(provider, makeModel(['video']), makeSupport({ video: true })).supportsVideo,
    ).toBe(true);
    expect(
      resolveAttachmentCapabilities(provider, makeModel(['video']), makeSupport({})).supportsVideo,
    ).toBe(false);
  });

  it('file is supported when either textFileInline or nativeFile is, independently of model capabilities', () => {
    expect(
      resolveAttachmentCapabilities(provider, makeModel([]), makeSupport({ textFileInline: true })).supportsFile,
    ).toBe(true);
    expect(
      resolveAttachmentCapabilities(provider, makeModel([]), makeSupport({ nativeFile: true })).supportsFile,
    ).toBe(true);
    expect(resolveAttachmentCapabilities(provider, makeModel([]), makeSupport({})).supportsFile).toBe(false);
  });

  it('supportsAttachment is the union of the three', () => {
    expect(
      resolveAttachmentCapabilities(provider, makeModel(['image']), makeSupport({ image: true })).supportsAttachment,
    ).toBe(true);
    expect(
      resolveAttachmentCapabilities(provider, makeModel([]), makeSupport({ textFileInline: true })).supportsAttachment,
    ).toBe(true);
    expect(
      resolveAttachmentCapabilities(provider, makeModel([]), makeSupport({})).supportsAttachment,
    ).toBe(false);
  });

  it('everything is false when model and provider are null', () => {
    expect(resolveAttachmentCapabilities(null, null, null)).toEqual({
      supportsImage: false,
      supportsVideo: false,
      supportsFile: false,
      supportsAttachment: false,
    });
  });
});

describe('canAcceptDroppedAttachment', () => {
  const model = makeModel(['image']);

  it('an image attachment is judged by the image capability', () => {
    expect(canAcceptDroppedAttachment(makeAttachment('image'), provider, model, makeSupport({ image: true }))).toBe(true);
    expect(canAcceptDroppedAttachment(makeAttachment('image'), provider, model, makeSupport({ image: false }))).toBe(false);
  });

  it('a file attachment is judged by the file capability', () => {
    expect(
      canAcceptDroppedAttachment(makeAttachment('file'), provider, model, makeSupport({ textFileInline: true })),
    ).toBe(true);
    expect(canAcceptDroppedAttachment(makeAttachment('file'), provider, model, makeSupport({}))).toBe(false);
  });

  it('a video attachment takes the file branch and ignores the video capability', () => {
    // Even when both the model and the provider support video, a drop is judged by the file capability.
    expect(
      canAcceptDroppedAttachment(makeAttachment('video'), provider, makeModel(['video']), makeSupport({ video: true })),
    ).toBe(false);
    expect(
      canAcceptDroppedAttachment(
        makeAttachment('video'),
        provider,
        makeModel(['video']),
        makeSupport({ video: true, textFileInline: true }),
      ),
    ).toBe(true);
  });
});

describe('buildAcceptAttribute', () => {
  it('image support alone yields image/*', () => {
    expect(buildAcceptAttribute(provider, makeModel(['image']), makeSupport({ image: true }))).toBe('image/*');
  });

  it('image plus nativeFile yields image/* first, then .pdf and .docx', () => {
    const accept = buildAcceptAttribute(provider, makeModel(['image']), makeSupport({ image: true, nativeFile: true }));
    expect(accept.startsWith('image/*,')).toBe(true);
    expect(accept).toContain('.pdf');
    expect(accept).toContain('.docx');
  });

  it('textFileInline without nativeFile yields text extensions but neither image/* nor .pdf', () => {
    const accept = buildAcceptAttribute(provider, makeModel([]), makeSupport({ textFileInline: true }));
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
      [history, turn], 'now', provider, makeModel(['text']),
      makeSupport({ image: true, textFileInline: true }),
    );
    // The model has no image / video capability: only files remain
    expect(out[1].attachments).toEqual([file]);
    expect(out[0]).toBe(history);
  });

  it('files depend on whether the connection accepts files', () => {
    const out = filterCurrentTurnAttachments(
      [turn], 'now', provider, makeModel(['text', 'image']), makeSupport({ image: true }),
    );
    expect(out[0].attachments).toEqual([image]);
  });

  it('support table not loaded yet (null): unknown is not unsupported, returned as is', () => {
    const messages = [turn];
    expect(filterCurrentTurnAttachments(messages, 'now', provider, makeModel(['text']), null)).toBe(messages);
  });

  it('attachments are cleared when none is accepted; the same array is returned unchanged when all are accepted', () => {
    expect(filterCurrentTurnAttachments(
      [turn], 'now', provider, makeModel(['text']), makeSupport({}),
    )[0].attachments).toBeUndefined();

    const messages = [{ id: 'now', attachments: [file] }];
    expect(filterCurrentTurnAttachments(
      messages, 'now', provider, makeModel(['text']), makeSupport({ textFileInline: true }),
    )).toBe(messages);
  });
});
