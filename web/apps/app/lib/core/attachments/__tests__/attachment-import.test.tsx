/**
 * The unified attachment import flow: two interleaved batches neither lose attachments nor exceed
 * the limit, and an extraction failure is announced at import time.
 *
 * Real React state connects the two entry points (useAttachmentIntake for the file picker,
 * useAttachmentDragDrop for drag and drop and paste) to one attachment tray, the way ChatView
 * wires them. Only the "read and convert the files" step is replaced, so the test controls when
 * it completes.
 */
import { act, render } from '@testing-library/react';
import { useCallback, useState } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment } from '@oriveo/shared';
import {
  __resetAttachmentImportQueueForTest,
  appendAttachmentsWithinLimit,
  extractionFailureCopyKey,
  resolveImportTextLimits,
} from '../attachment-import';
import { DEFAULT_LIMITS } from '../file-text-extractor';
import { useAttachmentIntake } from '../../../hooks/useAttachmentIntake';
import { useAttachmentDragDrop } from '../../../hooks/useAttachmentDragDrop';

const { mockValidateAndConvertFiles, mockShowToast } = vi.hoisted(() => ({
  mockValidateAndConvertFiles: vi.fn(),
  mockShowToast: vi.fn(),
}));

vi.mock('../../../utils/attachment-utils-lazy', () => ({
  loadAttachmentUtils: () => Promise.resolve({ validateAndConvertFiles: mockValidateAndConvertFiles }),
}));
vi.mock('../../../../components/Toast', () => ({ showToast: mockShowToast }));
vi.mock('next-intl', () => {
  const translate = (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key;
  return { useTranslations: () => translate };
});

vi.mock('../../telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../telemetry')>()),
  trackEvent: vi.fn(),
}));

/** The real "read the files and convert" step. Tests that assert on the production conversion point the mock back at it. */
const realValidateAndConvertFiles = async (...args: unknown[]) => {
  const actual = await vi.importActual<typeof import('../../../utils/attachment-utils')>(
    '../../../utils/attachment-utils',
  );
  return (actual.validateAndConvertFiles as (...inner: unknown[]) => Promise<Attachment[]>)(...args);
};

const file = (name: string) => new File(['x'], name, { type: 'text/plain' });
const toAttachment = (source: File, extra: Partial<Attachment> = {}): Attachment => ({
  id: `att-${source.name}`,
  kind: 'file',
  fileName: source.name,
  mimeType: 'text/plain',
  ...extra,
});

interface Harness {
  attachments: Attachment[];
  pickFiles: (files: File[]) => Promise<void>;
  dropFiles: (files: File[]) => Promise<void>;
  remove: (id: string) => void;
}

function renderComposer(
  options: { model?: AIModel | null } = {},
): { current: Harness } {
  const handle = { current: null as unknown as Harness };
  function Composer() {
    const [attachments, setAttachments] = useState<Attachment[]>([]);
    const intake = useAttachmentIntake({
      attachments,
      onAttachmentsChange: setAttachments,
      supportsImage: true,
      currentModel: options.model,
    });
    const onFilesAccepted = useCallback((incoming: Attachment[], max: number) => {
      setAttachments((current) => appendAttachmentsWithinLimit(current, incoming, max));
    }, []);
    const { dragHandlers } = useAttachmentDragDrop(onFilesAccepted, undefined, {
      existingAttachments: attachments,
      currentModel: options.model,
    });
    handle.current = {
      attachments,
      pickFiles: intake.handleAddFiles,
      dropFiles: (files) => dragHandlers.onDrop({ preventDefault: () => {}, dataTransfer: { files } } as never),
      remove: intake.handleRemoveAttachment,
    };
    return null;
  }
  render(<Composer />);
  return handle;
}

/** Lets queued imports and React renders run to completion. */
const settle = () => act(async () => { await new Promise((resolve) => setTimeout(resolve, 20)); });

describe('importAttachmentFiles', () => {
  beforeEach(() => {
    __resetAttachmentImportQueueForTest();
    mockValidateAndConvertFiles.mockReset();
    mockShowToast.mockReset();
    mockValidateAndConvertFiles.mockImplementation(async (files: File[]) => files.map((item) => toAttachment(item)));
  });

  afterEach(() => vi.restoreAllMocks());

  it('keeps both batches when the second arrives before the first has written back, caps the total at 3 and does not read the excess', async () => {
    const composer = renderComposer();
    let finishFirstBatch!: () => void;
    mockValidateAndConvertFiles.mockImplementationOnce((files: File[]) => new Promise<Attachment[]>((resolve) => {
      finishFirstBatch = () => resolve(files.map((item) => toAttachment(item)));
    }));

    // The first batch (file picker) has started reading and has not written back when the second
    // (drag and drop) arrives. Both entry points see an empty tray at this point.
    let first!: Promise<void>;
    let second!: Promise<void>;
    await act(async () => {
      first = composer.current.pickFiles([file('a1.txt'), file('a2.txt')]);
      second = composer.current.dropFiles([file('b1.txt'), file('b2.txt')]);
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(composer.current.attachments).toEqual([]);
    expect(mockValidateAndConvertFiles).toHaveBeenCalledTimes(1);

    await act(async () => {
      finishFirstBatch();
      await Promise.all([first, second]);
    });
    await settle();

    expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['a1.txt', 'a2.txt', 'b1.txt']);
    // The second batch's gate saw the first batch's result: one slot was left and b2 was never read.
    expect((mockValidateAndConvertFiles.mock.calls[1]?.[0] as File[]).map((item) => item.name)).toEqual(['b1.txt']);
    expect(mockShowToast).toHaveBeenCalledWith('tooManyFiles({"maxFiles":3})');
  });

  it('cuts the write-back to the real length at merge time, so a stale gate can neither exceed the limit nor overwrite', () => {
    const existing = ['a', 'b'].map((name) => toAttachment(file(`${name}.txt`)));
    const incoming = ['c', 'd'].map((name) => toAttachment(file(`${name}.txt`)));

    expect(appendAttachmentsWithinLimit(existing, incoming, 3).map((item) => item.fileName))
      .toEqual(['a.txt', 'b.txt', 'c.txt']);
    const full = [...existing, incoming[0]];
    expect(appendAttachmentsWithinLimit(full, [incoming[1]], 3)).toBe(full);
  });

  it('does not drop a freshly merged batch when an attachment is removed mid-import', async () => {
    const composer = renderComposer();
    await act(async () => { await composer.current.pickFiles([file('keep.txt'), file('drop.txt')]); });
    await settle();

    let finish!: () => void;
    mockValidateAndConvertFiles.mockImplementationOnce((files: File[]) => new Promise<Attachment[]>((resolve) => {
      finish = () => resolve(files.map((item) => toAttachment(item)));
    }));
    let pending!: Promise<void>;
    await act(async () => {
      pending = composer.current.dropFiles([file('late.txt')]);
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    // This remove callback was created before late.txt was merged in.
    const removeCapturedEarlier = composer.current.remove;
    await act(async () => { finish(); await pending; });
    act(() => removeCapturedEarlier('att-drop.txt'));
    await settle();

    expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['keep.txt', 'late.txt']);
  });

  describe('the text budget is enforced when attachments are added, not skipped silently by the injector at send time', () => {
    const CAP = DEFAULT_LIMITS.totalCap;
    const withText = (bytes: number) => (files: File[]) =>
      Promise.resolve(files.map((item) => toAttachment(item, { base64Data: 'x'.repeat(bytes) })));

    it('accepts a single file that exactly fills the budget, without a notice', async () => {
      const composer = renderComposer();
      mockValidateAndConvertFiles.mockImplementationOnce(withText(CAP));
      await act(async () => { await composer.current.pickFiles([file('full.txt')]); });
      await settle();
      expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['full.txt']);
      expect(mockShowToast).not.toHaveBeenCalled();
    });

    it('leaves out the second of two 150KB files in one batch and says why', async () => {
      const composer = renderComposer();
      mockValidateAndConvertFiles.mockImplementationOnce(withText(150 * 1024));
      await act(async () => { await composer.current.pickFiles([file('a.txt'), file('b.txt')]); });
      await settle();
      expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['a.txt']);
      expect(mockShowToast).toHaveBeenCalledExactlyOnceWith('textBudgetExceeded({"fileName":"b.txt"})');
    });

    it('counts text already in the tray: a later file that does not fit is left out and one that fits is added', async () => {
      const composer = renderComposer();
      mockValidateAndConvertFiles.mockImplementationOnce(withText(150 * 1024));
      await act(async () => { await composer.current.pickFiles([file('a.txt')]); });
      await settle();
      mockValidateAndConvertFiles.mockImplementationOnce(async (files: File[]) => files.map((item) =>
        toAttachment(item, { base64Data: 'x'.repeat(item.name === 'big.txt' ? 100 * 1024 : 1024) })));
      await act(async () => { await composer.current.pickFiles([file('big.txt'), file('small.txt')]); });
      await settle();
      expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['a.txt', 'small.txt']);
      expect(mockShowToast).toHaveBeenCalledExactlyOnceWith('textBudgetExceeded({"fileName":"big.txt"})');
    });

    // A multi-line oversized text is added truncated (see "long text is added truncated" below). A single line
    // that is itself over the budget is cut inside the line and added too. Run the real conversion to confirm it
    // does not become an empty attachment.
    it('keeps the start of a single-line file that is over the budget and says it was truncated', async () => {
      const composer = renderComposer();
      mockValidateAndConvertFiles.mockImplementationOnce(realValidateAndConvertFiles);
      const huge = new File(['x'.repeat(CAP + 1)], 'huge.txt', { type: 'text/plain' });
      await act(async () => { await composer.current.pickFiles([huge]); });
      await settle();
      const [attachment] = composer.current.attachments;
      expect(attachment?.fileName).toBe('huge.txt');
      expect(attachment?.extractedTruncated).toBe(true);
      expect(attachment?.base64Data).toHaveLength(CAP);
      expect(mockShowToast).toHaveBeenCalledExactlyOnceWith(
        'truncatedNotice({"fileName":"huge.txt","shown":1,"total":1})',
      );
    });

    // Files with original bytes (PDF / Office) may be uploaded natively instead of injected as text;
    // the model is unknown at import time, so they cannot be rejected by text size.
    it('does not charge images or files that may be uploaded natively against the text budget', async () => {
      const composer = renderComposer();
      mockValidateAndConvertFiles.mockImplementationOnce(async (files: File[]) => [
        toAttachment(files[0]!, { base64Data: 'x'.repeat(CAP), originalBase64Data: 'raw' }),
        toAttachment(files[1]!, { base64Data: 'x'.repeat(CAP), originalBase64Data: 'raw' }),
        toAttachment(files[2]!, { kind: 'image', base64Data: 'x'.repeat(CAP + 1) }),
      ]);
      await act(async () => { await composer.current.pickFiles([file('a.pdf'), file('b.pdf'), file('c.png')]); });
      await settle();
      expect(composer.current.attachments).toHaveLength(3);
      expect(mockShowToast).not.toHaveBeenCalled();
    });
  });

  // This group does not replace "read the files and convert": the attachment objects and the line counts in the notice
  // both come from what the production conversion path actually produces.
  describe('long text is added truncated, and the notice says how many lines were kept', () => {
    const lines = (count: number, width = 8) =>
      Array.from({ length: count }, (_, i) => `${i + 1}`.padEnd(width, '.')).join('\n');
    const textFile = (name: string, content: string) => new File([content], name, { type: 'text/plain' });

    beforeEach(() => { mockValidateAndConvertFiles.mockImplementation(realValidateAndConvertFiles); });

    it('text over the line cap: added, marked truncated, one notice', async () => {
      const composer = renderComposer();
      await act(async () => { await composer.current.pickFiles([textFile('long.txt', lines(600))]); });
      await settle();
      const [attachment] = composer.current.attachments;
      expect(attachment?.fileName).toBe('long.txt');
      expect(attachment?.extractedTruncated).toBe(true);
      expect(attachment?.base64Data?.split('\n')).toHaveLength(DEFAULT_LIMITS.maxLines);
      expect(mockShowToast).toHaveBeenCalledExactlyOnceWith(
        'truncatedNotice({"fileName":"long.txt","shown":500,"total":600})',
      );
    });

    it('a .txt over 200KB is added truncated instead of rejected', async () => {
      const composer = renderComposer();
      const big = textFile('big.txt', lines(400, 1023));
      expect(big.size).toBeGreaterThan(DEFAULT_LIMITS.totalCap);
      await act(async () => { await composer.current.pickFiles([big]); });
      await settle();
      const [attachment] = composer.current.attachments;
      expect(attachment?.fileName).toBe('big.txt');
      expect(attachment?.extractedTruncated).toBe(true);
      expect(new TextEncoder().encode(attachment?.base64Data ?? '').byteLength)
        .toBeLessThanOrEqual(DEFAULT_LIMITS.totalCap);
      expect(mockShowToast).toHaveBeenCalledExactlyOnceWith(
        'truncatedNotice({"fileName":"big.txt","shown":200,"total":400})',
      );
    });

    it('two truncated files in one batch: a single notice, one line per file', async () => {
      const composer = renderComposer();
      await act(async () => {
        await composer.current.pickFiles([textFile('a.txt', lines(600)), textFile('b.txt', lines(700))]);
      });
      await settle();
      expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['a.txt', 'b.txt']);
      expect(mockShowToast).toHaveBeenCalledTimes(1);
      expect(mockShowToast.mock.calls[0]?.[0]).toBe([
        'truncatedNotice({"fileName":"a.txt","shown":500,"total":600})',
        'truncatedNotice({"fileName":"b.txt","shown":500,"total":700})',
      ].join('\n'));
    });

    it('text that was not truncated gets no notice', async () => {
      const composer = renderComposer();
      await act(async () => { await composer.current.pickFiles([textFile('short.txt', lines(10))]); });
      await settle();
      expect(composer.current.attachments[0]?.extractedTruncated).toBe(false);
      expect(mockShowToast).not.toHaveBeenCalled();
    });
  });

  // This group also runs the real conversion: the line and byte counts are cut by the production import path to the model's limits.
  describe('import truncates and checks the total against the limits the current model declares', () => {
    const lines = (count: number, width = 8) =>
      Array.from({ length: count }, (_, i) => `${i + 1}`.padEnd(width, '.')).join('\n');
    const textFile = (name: string, content: string) => new File([content], name, { type: 'text/plain' });
    const modelWith = (attachmentExtraction: AIModel['attachmentExtraction']) =>
      ({ id: 'm', name: 'm', attachmentExtraction }) as AIModel;
    const MB = 1024 * 1024;

    beforeEach(() => { mockValidateAndConvertFiles.mockImplementation(realValidateAndConvertFiles); });

    it('a model that tightens the line cap to 100: both the picker and drag and drop truncate at 100 lines and say so', async () => {
      const composer = renderComposer({ model: modelWith({ maxLines: 100 }) });
      await act(async () => { await composer.current.pickFiles([textFile('picked.txt', lines(600))]); });
      await settle();
      await act(async () => { await composer.current.dropFiles([textFile('dropped.txt', lines(300))]); });
      await settle();
      expect(composer.current.attachments.map((item) => item.base64Data?.split('\n').length)).toEqual([100, 100]);
      expect(mockShowToast.mock.calls.map(([text]) => text)).toEqual([
        'truncatedNotice({"fileName":"picked.txt","shown":100,"total":600})',
        'truncatedNotice({"fileName":"dropped.txt","shown":100,"total":300})',
      ]);
    });

    it('a model that relaxes the per-file bytes and the total to 1MB: a 300KB text is added whole, without truncation or a notice', async () => {
      const composer = renderComposer({ model: modelWith({ maxBytes: MB, totalCap: MB }) });
      const big = textFile('big.txt', lines(300, 1023));
      expect(big.size).toBeGreaterThan(DEFAULT_LIMITS.totalCap);
      await act(async () => { await composer.current.pickFiles([big]); });
      await settle();
      const [attachment] = composer.current.attachments;
      expect(attachment?.extractedTruncated).toBe(false);
      expect(attachment?.base64Data?.split('\n')).toHaveLength(300);
      expect(mockShowToast).not.toHaveBeenCalled();
    });

    it('a model that tightens the total to 50KB: the second 30KB file is not added, with an explanation', async () => {
      const composer = renderComposer({ model: modelWith({ totalCap: 50 * 1024 }) });
      await act(async () => {
        await composer.current.pickFiles([textFile('a.txt', lines(30, 1023)), textFile('b.txt', lines(30, 1023))]);
      });
      await settle();
      expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['a.txt']);
      expect(mockShowToast).toHaveBeenCalledExactlyOnceWith('textBudgetExceeded({"fileName":"b.txt"})');
    });

    // The count cap accepts the maxAttachments declared by the model.
    it('a model that declares maxAttachments=2: the third file is not added, and the limit in the notice is 2', async () => {
      const composer = renderComposer({
        model: { id: 'm', name: 'M', capabilities: ['text'], attachmentExtraction: { maxAttachments: 2 } } as unknown as AIModel,
      });
      await act(async () => { await composer.current.pickFiles([file('a.txt'), file('b.txt'), file('c.txt')]); });
      await settle();
      expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['a.txt', 'b.txt']);
      expect(mockShowToast).toHaveBeenCalledExactlyOnceWith('tooManyFiles({"maxFiles":2})');
    });

    it('without a model: the same as the default limits', () => {
      expect(resolveImportTextLimits(undefined)).toEqual(DEFAULT_LIMITS);
      expect(resolveImportTextLimits(null)).toEqual(DEFAULT_LIMITS);
    });
  });

  describe('an extraction failure is announced at import time; apart from scanned PDFs the file does not enter the tray', () => {
    it.each([
      ['encrypted_pdf', 'errorPasswordProtected({"fileName":"report.pdf"})'],
      ['password_protected_office', 'errorPasswordProtected({"fileName":"report.pdf"})'],
      ['corrupted_file', 'errorCorrupted({"fileName":"report.pdf"})'],
      ['unsupported_format', 'errorUnsupported({"fileName":"report.pdf"})'],
      // The limit is the input file size actually in effect (50MB by default), rounded down
      ['file_too_large', 'errorTooLarge({"fileName":"report.pdf","maxMB":50})'],
      ['extraction_timeout', 'errorGeneric({"fileName":"report.pdf"})'],
      ['extraction_error', 'errorGeneric({"fileName":"report.pdf"})'],
    ])('%s: only a notice, not added', async (errorCode, toast) => {
      const composer = renderComposer();
      mockValidateAndConvertFiles.mockImplementationOnce(async (files: File[]) =>
        files.map((item) => toAttachment(item, { extractionErrorCode: errorCode, base64Data: '', originalBase64Data: 'raw' })));

      await act(async () => { await composer.current.pickFiles([file('report.pdf')]); });
      await settle();

      expect(mockShowToast).toHaveBeenCalledExactlyOnceWith(toast);
      expect(composer.current.attachments).toEqual([]);
    });

    it('scanned_pdf: still added with its error code kept (it can fall back to native upload), with a notice', async () => {
      const composer = renderComposer();
      mockValidateAndConvertFiles.mockImplementationOnce(async (files: File[]) =>
        files.map((item) => toAttachment(item, { extractionErrorCode: 'scanned_pdf', base64Data: '' })));

      await act(async () => { await composer.current.pickFiles([file('report.pdf')]); });
      await settle();

      expect(mockShowToast).toHaveBeenCalledExactlyOnceWith('errorNoText({"fileName":"report.pdf"})');
      expect(composer.current.attachments).toEqual([
        expect.objectContaining({ fileName: 'report.pdf', extractionErrorCode: 'scanned_pdf' }),
      ]);
    });

    // The toast has a single slot: shown one by one, only the last notice of a batch would be seen.
    it('summarizes a batch with several failures and too many files into one toast that keeps every notice', async () => {
      const composer = renderComposer();
      const codes: Record<string, string> = { 'a.pdf': 'encrypted_pdf', 'c.pdf': 'scanned_pdf' };
      mockValidateAndConvertFiles.mockImplementationOnce(async (files: File[]) =>
        files.map((item) => toAttachment(item, codes[item.name] ? { extractionErrorCode: codes[item.name], base64Data: '' } : {})));

      await act(async () => {
        await composer.current.pickFiles([file('a.pdf'), file('b.txt'), file('c.pdf'), file('d.txt')]);
      });
      await settle();

      const tooMany = 'tooManyFiles({"maxFiles":3})';
      expect(mockShowToast.mock.calls.at(-1)?.[0]).toBe([
        tooMany,
        'errorPasswordProtected({"fileName":"a.pdf"})',
        'errorNoText({"fileName":"c.pdf"})',
      ].join('\n'));
      // "Too many files" is shown once before the files are read; after that only the summary follows.
      expect(mockShowToast.mock.calls.map(([message]) => message)).toEqual([tooMany, expect.stringContaining('\n')]);
      // The password-protected a.pdf is not added; the scanned c.pdf is added as usual
      expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['b.txt', 'c.pdf']);
    });

    it('shows nothing for an attachment that extracted successfully', async () => {
      const composer = renderComposer();
      await act(async () => { await composer.current.pickFiles([file('ok.txt')]); });
      await settle();
      expect(mockShowToast).not.toHaveBeenCalled();
      expect(extractionFailureCopyKey(undefined)).toBeNull();
    });
  });
});
