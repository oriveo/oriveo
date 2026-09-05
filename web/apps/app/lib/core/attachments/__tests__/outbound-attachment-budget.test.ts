import { describe, it, expect } from 'vitest';
import type { Attachment, ChatMessage, ChatRole } from '@oriveo/shared';
import {
  DEFAULT_OUTBOUND_ATTACHMENT_BUDGET_BYTES,
  applyOutboundAttachmentBudget,
} from '../outbound-attachment-budget';

/**
 * The same conversation must have the same attachments trimmed on every client, otherwise the
 * model appears to have a different memory depending on which one the user opens.
 */

const ONE_MB = 1024 * 1024;

function image(name: string, localImageID = `img-${name}`): Attachment {
  return {
    id: name,
    kind: 'image',
    fileName: `${name}.jpg`,
    mimeType: 'image/jpeg',
    localImageID,
  };
}

const RAW_PDF_BYTES = 'A'.repeat(4 * ONE_MB);

/** `extractedText: null` means the field is missing entirely; `''` is the explicit marker for "extraction ran and found no text". */
function pdf(name: string, extractedText: string | null = 'ZXh0cmFjdGVk'): Attachment {
  return {
    id: name,
    kind: 'file',
    fileName: `${name}.pdf`,
    mimeType: 'application/pdf',
    ...(extractedText === null ? {} : { base64Data: extractedText }),
    originalBase64Data: RAW_PDF_BYTES,
  };
}

function message(role: ChatRole, text: string, attachments?: Attachment[]): ChatMessage {
  return {
    id: `${role}-${text}`,
    role,
    text,
    providerKind: 'openAI',
    providerName: 'OpenAI',
    modelName: 'gpt-test',
    estimatedCost: 0,
    state: 'delivered',
    ...(attachments ? { attachments } : {}),
  };
}

const user = (text: string, ...attachments: Attachment[]) =>
  message('user', text, attachments.length > 0 ? attachments : undefined);
const assistant = (text: string) => message('assistant', text);

/** The disk probe returns 3MB by default; individual cases override it when they need another size. */
const apply = (
  messages: ChatMessage[],
  budgetBytes: number,
  imageRawBytes: number | (() => number) = 3 * ONE_MB,
) => applyOutboundAttachmentBudget(messages, {
  budgetBytes,
  imageSizeOf: typeof imageRawBytes === 'function' ? imageRawBytes : () => imageRawBytes,
});

describe('applyOutboundAttachmentBudget', () => {
  it('returns the input unchanged when there are no attachments', async () => {
    const messages = [user('hi'), assistant('hello')];

    const out = await apply(messages, 0);

    expect(out).toBe(messages);
  });

  it('never trims the input of the current turn, even when it fills the whole budget on its own', async () => {
    const messages = [user('look at this', image('a'))];

    const out = await apply(messages, 1, 25 * ONE_MB);

    expect(out[0].attachments).toEqual([image('a')]);
    expect(out[0].text).toBe('look at this');
  });

  it('degrades an over-budget historical image into a placeholder line', async () => {
    // One 3MB source image becomes 4MB of base64, so a 5MB budget only fits the most recent one.
    const messages = [
      user('first', image('old')),
      assistant('ok'),
      user('second', image('recent')),
      assistant('ok'),
      user('third'),
    ];

    const out = await apply(messages, 5 * ONE_MB, 3 * ONE_MB);

    // The most recent history entry with an image is kept.
    expect(out[2].attachments).toEqual([image('recent')]);
    // The older one is replaced by a placeholder line.
    expect(out[0].attachments).toBeUndefined();
    expect(out[0].text.startsWith('first')).toBe(true);
    expect(out[0].text).toContain('[Image omitted: old.jpg');
    // The input message objects must not be mutated in place: the caller holds the real messages from the store.
    expect(messages[0].attachments).toEqual([image('old')]);
    expect(messages[0].text).toBe('first');
  });

  it('keeps the extracted text of an over-budget historical file and drops only the raw bytes', async () => {
    const messages = [
      user('read this', pdf('report')),
      assistant('ok'),
      user('and now this?'),
    ];

    const out = await apply(messages, 0, 25 * ONE_MB);

    const kept = out[0].attachments!;
    expect(kept).toHaveLength(1);
    expect(kept[0].base64Data).toBe('ZXh0cmFjdGVk');
    expect(kept[0].originalBase64Data).toBeUndefined();
    // Keeping the attachment means no placeholder line should be added.
    expect(out[0].text).toBe('read this');
  });

  it('drops a historical file with no extracted text entirely and adds a placeholder line', async () => {
    const messages = [
      user('binary blob', pdf('scan', null)),
      assistant('ok'),
      user('next'),
    ];

    const out = await apply(messages, 0, 25 * ONE_MB);

    expect(out[0].attachments).toBeUndefined();
    expect(out[0].text).toContain('[File omitted: scan.pdf');
  });

  it('does not treat the empty-string marker of a scanned document as usable text', async () => {
    // base64Data === '' is the explicit marker for "extraction really found no text" and must not be treated as usable body text.
    const messages = [
      user('scanned', pdf('scanned', '')),
      assistant('ok'),
      user('next'),
    ];

    const out = await apply(messages, 0, 25 * ONE_MB);

    expect(out[0].attachments).toBeUndefined();
    expect(out[0].text).toContain('[File omitted: scanned.pdf');
  });

  it('makes the placeholder line the body of an image-only message once it is trimmed', async () => {
    const messages = [
      user('', image('lonely')),
      assistant('ok'),
      user('follow up'),
    ];

    const out = await apply(messages, 0, ONE_MB);

    expect(out[0].attachments).toBeUndefined();
    expect(out[0].text).toBe(
      '[Image omitted: lonely.jpg (older attachment dropped to keep this request small)]',
    );
  });

  it('does not double-count disk cost for an already inlined base64 image and does not probe the disk', async () => {
    const inlined: Attachment = { ...image('cached'), base64Data: 'AAAA' };
    const messages = [
      user('older', inlined),
      assistant('ok'),
      user('newer'),
    ];

    const out = await apply(messages, 1024, () => {
      throw new Error('an already inlined base64 image must not be measured against the disk');
    });

    expect(out[0].attachments).toEqual([inlined]);
  });

  it('measures the budget in base64 bytes against a 10MiB limit', () => {
    expect(DEFAULT_OUTBOUND_ATTACHMENT_BUDGET_BYTES).toBe(10 * 1024 * 1024);
  });

  it('drops a video entirely and adds a Video placeholder line', async () => {
    // A video has no "slim down" path, since the payload is the video itself, so it can only be dropped whole.
    const clip: Attachment = {
      id: 'clip',
      kind: 'video',
      fileName: 'clip.mp4',
      mimeType: 'video/mp4',
      base64Data: 'A'.repeat(1024),
    };
    const messages = [user('old clip', clip), assistant('ok'), user('next')];

    const out = await apply(messages, 0, 0);

    expect(out[0].attachments).toBeUndefined();
    expect(out[0].text).toContain('[Video omitted: clip.mp4');
  });
});
