import { describe, it, expect, vi, beforeEach } from 'vitest';

const mocks = vi.hoisted(() => ({
  getActiveUID: vi.fn().mockResolvedValue('guest'),
  getActiveUIDSync: vi.fn().mockReturnValue('guest'),
  saveImage: vi.fn().mockResolvedValue(undefined),
  uploadAttachmentIfNeeded: vi.fn().mockResolvedValue(null),
  uploadFileAttachmentIfNeeded: vi.fn().mockResolvedValue(null),
  getSyncAdapter: vi.fn().mockReturnValue(null),
  imageExists: vi.fn().mockResolvedValue(true),
}));

// mock ImageStore
vi.mock('../../infra/storage/image-store', () => ({
  saveImage: mocks.saveImage,
  generateThumbnail: vi.fn().mockResolvedValue(new Blob(['thumb'], { type: 'image/jpeg' })),
  imageExists: mocks.imageExists,
}));

// mock sync
vi.mock('../../core/sync-port', () => ({
  getSyncAdapter: mocks.getSyncAdapter,
  uploadAttachmentIfNeeded: mocks.uploadAttachmentIfNeeded,
  uploadFileAttachmentIfNeeded: mocks.uploadFileAttachmentIfNeeded,
}));

// mock partition
vi.mock('../../infra/storage/partition', () => ({
  getActiveUID: mocks.getActiveUID,
  getActiveUIDSync: mocks.getActiveUIDSync,
}));

import {
  MAX_ATTACHMENT_BACKFILL_PER_LAUNCH,
  backfillMissingAttachmentUploads,
  backfillStorageRefs,
  collectMissingStorageRefAttachments,
  processImageAttachments,
} from '../stream-image-utils';

// mock FileReader for thumbnail base64
class MockFileReader {
  result: string | null = null;
  onloadend: (() => void) | null = null;
  readAsDataURL() {
    this.result = 'data:image/jpeg;base64,dGh1bWI=';
    setTimeout(() => this.onloadend?.(), 0);
  }
}
(globalThis as any).FileReader = MockFileReader;

function makeImageAtt(id: string, localImageID: string) {
  return {
    id,
    kind: 'image' as const,
    fileName: 'image.jpg',
    mimeType: 'image/jpeg',
    localImageID,
  };
}

describe('processImageAttachments', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getActiveUID.mockResolvedValue('guest');
    mocks.getActiveUIDSync.mockReturnValue('guest');
    mocks.uploadAttachmentIfNeeded.mockResolvedValue(null);
    mocks.uploadFileAttachmentIfNeeded.mockResolvedValue(null);
    mocks.getSyncAdapter.mockReturnValue(null);
  });

  it('should return text unchanged when no inline images', async () => {
    const { finalText, processedAttachments } = await processImageAttachments('Hello world', []);
    expect(finalText).toBe('Hello world');
    expect(processedAttachments).toHaveLength(0);
  });

  it('should extract inline base64 images from text', async () => {
    const b64 = 'iVBORw0KGgo=';
    const text = `Here is an image: ![alt](data:image/png;base64,${b64}) and more text`;
    const { finalText, processedAttachments } = await processImageAttachments(text, []);

    expect(finalText).not.toContain('data:image');
    expect(finalText).toBe('Here is an image:  and more text');
    expect(processedAttachments).toHaveLength(1);
    expect(processedAttachments[0].kind).toBe('image');
    expect(processedAttachments[0].localImageID).toBeDefined();
  });

  it('should process existing image attachments', async () => {
    const attachments = [{
      id: 'att-1',
      kind: 'image' as const,
      fileName: 'generated.png',
      mimeType: 'image/png',
      base64Data: 'iVBORw0KGgo=',
    }];

    const { processedAttachments } = await processImageAttachments('', attachments);

    expect(processedAttachments).toHaveLength(1);
    expect(processedAttachments[0].localImageID).toBeDefined();
    expect(processedAttachments[0].base64Data).toBeUndefined();
    expect(processedAttachments[0].thumbnailBase64).toBe('dGh1bWI=');
    expect(mocks.saveImage).toHaveBeenCalledWith(
      expect.any(String),
      expect.any(Blob),
      expect.any(Blob),
      'image/png',
      'guest',
    );
  });

  it('should handle mixed inline + existing attachments', async () => {
    const b64 = 'iVBORw0KGgo=';
    const text = `![img](data:image/png;base64,${b64})`;
    const existing = [{
      id: 'att-1',
      kind: 'image' as const,
      fileName: 'generated.png',
      mimeType: 'image/png',
      base64Data: 'aW1hZ2U=',
    }];

    const { processedAttachments } = await processImageAttachments(text, existing);
    expect(processedAttachments).toHaveLength(2);
  });

  it('should skip attachments without base64Data', async () => {
    const attachments = [{
      id: 'att-1',
      kind: 'image' as const,
      fileName: 'generated.png',
      mimeType: 'image/png',
      localImageID: 'already-stored',
    }];

    const { processedAttachments } = await processImageAttachments('', attachments);
    expect(processedAttachments[0].localImageID).toBe('already-stored');
  });

});

/**
 * Startup backfill: an upload is attempted once on the send path, and without this there is
 * never a second chance, so other clients are left with only a thumbnail.
 * These cases lock the scan predicate and the bounded, write-once-after-all-results handling.
 */
describe('startup backfill (backfillMissingAttachmentUploads)', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getActiveUID.mockResolvedValue('user-1');
    mocks.getActiveUIDSync.mockReturnValue('user-1');
    mocks.imageExists.mockResolvedValue(true);
    mocks.getSyncAdapter.mockReturnValue(null);
  });

  function makeConv(id: string, messages: any[]) {
    return { id, isDraft: false, messages } as any;
  }

  function makeMsg(id: string, attachments: any[], state = 'delivered') {
    return { id, role: 'user', text: '', state, attachments };
  }

  it('only picks up attachments that are delivered images with no storageRef whose local original is still present', async () => {
    mocks.imageExists.mockImplementation(async (imageId: string) => imageId !== 'evicted');
    const conversations = [
      makeConv('conv-1', [
        makeMsg('m1', [makeImageAtt('want', 'local-1')]),
        makeMsg('m2', [{ ...makeImageAtt('has-ref', 'local-2'), storageRef: 'users/user-1/attachments/local-2' }]),
        makeMsg('m3', [makeImageAtt('evicted-att', 'evicted')]),
        makeMsg('m4', [{ id: 'file-att', kind: 'file', fileName: 'a.pdf', mimeType: 'application/pdf' }]),
        makeMsg('m5', [makeImageAtt('not-delivered', 'local-3')], 'failed'),
      ]),
      { id: 'draft-conv', isDraft: true, messages: [makeMsg('m6', [makeImageAtt('draft', 'local-4')])] } as any,
    ];

    const targets = await collectMissingStorageRefAttachments(conversations, 'user-1');

    expect(targets.map((t) => t.att.id)).toEqual(['want']);
    expect(targets[0].msgID).toBe('m1');
    expect(targets[0].convId).toBe('conv-1');
  });

  it('caps how many are backfilled per startup and leaves the rest for the next one', async () => {
    const messages = Array.from({ length: MAX_ATTACHMENT_BACKFILL_PER_LAUNCH + 5 }, (_, i) =>
      makeMsg(`m${i}`, [makeImageAtt(`att-${i}`, `local-${i}`)]));
    const targets = await collectMissingStorageRefAttachments([makeConv('conv-1', messages)], 'user-1');
    expect(targets).toHaveLength(MAX_ATTACHMENT_BACKFILL_PER_LAUNCH);
  });

  it('skips guest uploads', async () => {
    const conversations = [makeConv('conv-1', [makeMsg('m1', [makeImageAtt('att-1', 'local-1')])])];

    await backfillMissingAttachmentUploads(conversations, 'user-1', () => conversations, vi.fn());
    expect(mocks.uploadAttachmentIfNeeded).not.toHaveBeenCalled();

    await backfillMissingAttachmentUploads(conversations, 'guest', () => conversations, vi.fn());
    expect(mocks.uploadAttachmentIfNeeded).not.toHaveBeenCalled();
  });
});
