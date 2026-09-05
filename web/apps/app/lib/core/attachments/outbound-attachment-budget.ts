import type { Attachment, ChatMessage } from '@oriveo/shared';

/**
 * Outbound attachment budget window: decides how much of the history's attachment payload is
 * worth sending again on this turn.
 *
 * Conversation history has no window of its own, so every turn resends the whole conversation to
 * the provider. `buildChatHistory` splices the base64 of every attachment on every history
 * message straight into the request body: images are read from IndexedDB at that moment via
 * `loadImageBase64()`, while the base64 of files and videos is already inline on the attachment.
 * The same content therefore exists several times over: the string on the attachment, the data
 * URI built from it, and the serialized JSON body, which also has to survive a retry. A 25MB PDF
 * is roughly 33MB of base64, times three about 100MB, and a few of those bring the tab down.
 *
 * The trim happens before the content is read, so an image that is dropped is never read out of
 * IndexedDB at all.
 *
 * The rules:
 * - The current turn is never trimmed: attachments on the last user message were just added by
 *   the user and have to arrive intact.
 * - History accumulates size from newest to oldest, and once over budget:
 *   - images and videos lose the whole attachment, with a placeholder line appended to the body
 *     so the model can tell there used to be an image there;
 *   - files keep their extracted text and lose only the raw bytes (`originalBase64Data` is
 *     cleared). `decideAttachmentRoute` sees an empty `originalBase64Data` and falls back to
 *     client_extract, which trades a 25MB raw PDF for a few dozen KB of extracted text while
 *     keeping most of the context value. A file with no extracted text is dropped entirely.
 *
 * The module does not depend on the storage layer: the size probe is injected by the caller, so
 * it can be verified outside a browser runtime.
 */

/**
 * History attachment budget, 10MiB, measured in base64 bytes, which is what these attachments
 * eventually add to the request body.
 *
 * Base64 bytes rather than raw bytes so that images in IndexedDB and already-inlined base64 are
 * measured with the same ruler.
 */
export const DEFAULT_OUTBOUND_ATTACHMENT_BUDGET_BYTES = 10 * 1024 * 1024;

export interface OutboundAttachmentBudgetOptions {
  budgetBytes?: number;
  /**
   * Raw byte count of the original image in IndexedDB, before base64.
   * It has to be a probe that works without reading the content, or the budget window would eat
   * back the very memory it is trying to save.
   */
  imageSizeOf: (localImageID: string) => Promise<number> | number;
}

/** How many bytes n raw bytes take once base64 encoded. */
function base64SizeOf(rawBytes: number): number {
  if (!Number.isFinite(rawBytes) || rawBytes <= 0) return 0;
  return Math.floor((rawBytes + 2) / 3) * 4;
}

/**
 * What is already inline on the attachment and really does end up in the request body.
 *
 * `.length` (UTF-16 code units) rather than UTF-8 byte count: base64 is all ASCII, so the two are
 * equivalent, and only a file's extracted text containing CJK differs slightly, which the 200KB
 * injection cap in AttachmentInjector keeps too small to change the trim decision.
 *
 * `downloadBase64Data` (the original file kept after a .docx is parsed into text) is not counted:
 * it never enters the request body.
 */
function inlineCost(attachment: Attachment): number {
  return (attachment.base64Data?.length ?? 0)
    + (attachment.originalBase64Data?.length ?? 0)
    + (attachment.thumbnailBase64?.length ?? 0);
}

/** How many base64 bytes this attachment eventually adds to the request body. */
async function costOf(
  attachment: Attachment,
  imageSizeOf: OutboundAttachmentBudgetOptions['imageSizeOf'],
): Promise<number> {
  const inline = inlineCost(attachment);
  // Video and file payloads are already inline on the attachment, so measure them directly.
  if (attachment.kind !== 'image') return inline;
  // A non-empty base64Data means the image has not landed in ImageStore yet (it was just
  // generated), so use it and skip IndexedDB. Note that buildChatHistory prefers localImageID
  // over base64Data, but the two never coexist: the paths that persist an image
  // (stream-image-utils, fileToAttachment) always clear base64Data when they set localImageID.
  if (attachment.base64Data) return inline;
  if (!attachment.localImageID) return inline;
  return inline + base64SizeOf(await imageSizeOf(attachment.localImageID));
}

/**
 * Returns a lightened copy when one can be kept, or null when the whole attachment has to go.
 * Only files with extracted text can be lightened: drop the raw bytes, keep the text.
 */
function lighten(attachment: Attachment): Attachment | null {
  if (attachment.kind !== 'file') return null;
  if (!attachment.originalBase64Data) return null;
  // base64Data === '' is the explicit marker for "no text could be extracted" (scanned PDF,
  // encrypted Office document, corrupt file), not usable text, so treat it like undefined.
  if (!attachment.base64Data) return null;
  const lightened: Attachment = { ...attachment };
  delete lightened.originalBase64Data;
  return lightened;
}

function placeholderFor(attachment: Attachment): string {
  const label = attachment.kind === 'image'
    ? 'Image'
    : attachment.kind === 'video' ? 'Video' : 'File';
  return `[${label} omitted: ${attachment.fileName} `
    + '(older attachment dropped to keep this request small)]';
}

function appendOmissions(text: string, omissions: string[]): string {
  if (omissions.length === 0) return text;
  return (text.trim().length > 0 ? [text, ...omissions] : omissions).join('\n\n');
}

/**
 * Trim history attachments on outbound messages to the budget. Returns a new array and never
 * mutates the message objects passed in, since the caller holds the real messages from the store
 * and the trim applies to this one request only.
 */
export async function applyOutboundAttachmentBudget(
  messages: ChatMessage[],
  options: OutboundAttachmentBudgetOptions,
): Promise<ChatMessage[]> {
  if (!messages.some((m) => (m.attachments?.length ?? 0) > 0)) return messages;

  const budgetBytes = options.budgetBytes ?? DEFAULT_OUTBOUND_ATTACHMENT_BUDGET_BYTES;
  const { imageSizeOf } = options;

  let lastUserIndex = -1;
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    if (messages[i].role === 'user') {
      lastUserIndex = i;
      break;
    }
  }

  const result = messages.slice();
  let used = 0;

  // Newest to oldest: the closer to this turn, the more an attachment deserves to stay.
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    const attachments = message.attachments;
    if (!attachments || attachments.length === 0) continue;

    const exempt = index === lastUserIndex;
    const kept: Attachment[] = [];
    const omissions: string[] = [];
    let changed = false;

    for (const attachment of attachments) {
      const cost = await costOf(attachment, imageSizeOf);
      if (exempt || used + cost <= budgetBytes) {
        used += cost;
        kept.push(attachment);
        continue;
      }
      const lightened = lighten(attachment);
      if (lightened) {
        used += inlineCost(lightened);
        kept.push(lightened);
        // Lightening keeps the count but changes the content: comparing counts alone would drop the lightened result.
        changed = true;
      } else {
        omissions.push(placeholderFor(attachment));
        changed = true;
      }
    }

    if (!changed) continue;
    result[index] = {
      ...message,
      text: appendOmissions(message.text, omissions),
      attachments: kept.length > 0 ? kept : undefined,
    };
  }

  return result;
}
