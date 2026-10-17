/**
 * Office file parsing utility: dispatches to each format's extractor per the attachment extraction output spec (dynamic imports avoid affecting first-screen load).
 *
 * - DOCX section 5, XLSX section 6, PPTX section 7, ODT / ODS / ODP section 9: one file each under `core/attachments/extractors/`;
 * - RTF section 11: `core/attachments/extractors/rtf-text-extractor.ts`.
 *
 * Every entry read from an archive goes through BoundedArchiveReader (decompression budget + the DOCTYPE / parsererror checks of section 15),
 * so a document that declares several GB of output, or carries a DTD, cannot exhaust the tab's memory.
 * Unrecognized formats throw `unsupported_format`.
 */

import type { ExtractionDeadline } from '../core/attachments/extraction-deadline';
import { classifyAttachmentFile } from '../core/attachments/attachment-file-types';
import { ExtractionError } from '../core/attachments/file-text-extractor';

/** Parse an Office file into plain text */
export async function parseOfficeFile(file: File, deadline?: ExtractionDeadline): Promise<string> {
  const kind = classifyAttachmentFile(file.name, file.type);

  if (kind === 'rtf') {
    const { extractRtfText } = await import('../core/attachments/extractors/rtf-text-extractor');
    return extractRtfText(new Uint8Array(await file.arrayBuffer()), deadline);
  }
  if (kind !== 'docx' && kind !== 'xlsx' && kind !== 'pptx' && kind !== 'odt' && kind !== 'ods' && kind !== 'odp') {
    throw new ExtractionError('unsupported_format', `not an office file: ${kind}`);
  }

  const { OfficePackage } = await import('../core/attachments/extractors/office-package');
  const pkg = await OfficePackage.open(await file.arrayBuffer(), deadline);

  switch (kind) {
    case 'docx': {
      const { extractDocxText } = await import('../core/attachments/extractors/docx-text-extractor');
      return extractDocxText(pkg);
    }
    case 'xlsx': {
      const { extractXlsxText } = await import('../core/attachments/extractors/xlsx-text-extractor');
      return extractXlsxText(pkg, deadline);
    }
    case 'pptx': {
      const { extractPptxText } = await import('../core/attachments/extractors/pptx-text-extractor');
      return extractPptxText(pkg, deadline);
    }
    default: {
      const { extractOdfText } = await import('../core/attachments/extractors/odf-text-extractor');
      return extractOdfText(pkg, deadline);
    }
  }
}
