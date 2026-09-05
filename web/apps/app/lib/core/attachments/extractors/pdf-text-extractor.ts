/**
 * PDF text extraction through a lazy pdfjs-dist import.
 *
 * - The worker configuration reuses the arrangement already proven in SkillEditPage.
 * - SSR guard: browser only.
 * - A scanned document with no text layer raises ExtractionError('scanned_pdf').
 * - An encrypted PDF raises ExtractionError('encrypted_pdf').
 */

import { ExtractionError } from '../file-text-extractor';

export async function extractPdfText(file: File): Promise<string> {
  // SSR guard.
  if (typeof window === 'undefined') {
    throw new ExtractionError('extraction_error', 'PDF extraction requires browser context');
  }

  const { getDocument, GlobalWorkerOptions } = await import('pdfjs-dist');
  // Reuses the worker configuration proven in SkillEditPage; webpack copies it into .next/static/media/.
  GlobalWorkerOptions.workerSrc = new URL(
    'pdfjs-dist/build/pdf.worker.min.mjs',
    import.meta.url,
  ).toString();

  let pdf: Awaited<ReturnType<typeof getDocument.prototype.promise>>;
  try {
    pdf = await getDocument({
      data: new Uint8Array(await file.arrayBuffer()),
      disableFontFace: true,  // No remote font downloads: better for privacy and offline use.
    }).promise;
  } catch (e: unknown) {
    const err = e as { name?: string; message?: string };
    if (err?.name === 'PasswordException') {
      throw new ExtractionError('encrypted_pdf', err.message);
    }
    throw new ExtractionError('corrupted_file', err?.message);
  }

  const parts: string[] = [];
  for (let i = 1; i <= pdf.numPages; i++) {
    const page = await pdf.getPage(i);
    const tc = await page.getTextContent();
    // tc.items: Array<TextItem | TextMarkedContent>
    const pageText = (tc.items as Array<{ str?: string }>)
      .map((it) => it.str ?? '')
      .join(' ')
      .trim();
    if (pageText) parts.push(pageText);
  }

  if (parts.length === 0) {
    throw new ExtractionError('scanned_pdf');
  }
  return parts.join('\n\n');
}
