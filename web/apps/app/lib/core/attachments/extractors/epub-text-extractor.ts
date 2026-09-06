/**
 * EPUB text extraction using JSZip and the OPF spine.
 *
 * 1. Parse META-INF/container.xml to find the OPF path.
 * 2. Parse the OPF for the manifest and the spine order.
 * 3. Read the XHTML chapters in spine order, reusing HtmlTextExtractor.
 *
 * Every entry is read through BoundedArchiveReader, so a book with a thousand chapters, or one
 * chapter that declares gigabytes, is refused instead of exhausting the tab.
 */

import { ExtractionError } from '../file-text-extractor';
import { assertArchiveWithinBudget, BoundedArchiveReader } from '../../../utils/zip-budget';
import { extractHtmlText } from './html-text-extractor';

export async function extractEpubText(file: File): Promise<string> {
  const JSZip = (await import('jszip')).default;
  let zip: InstanceType<typeof JSZip>;
  try {
    zip = await JSZip.loadAsync(await file.arrayBuffer());
  } catch (e: unknown) {
    const err = e as { message?: string };
    throw new ExtractionError('corrupted_file', err?.message);
  }
  assertArchiveWithinBudget(zip.files);
  const reader = new BoundedArchiveReader();

  // 1. Parse container.xml to find the OPF path.
  const containerFile = zip.file('META-INF/container.xml');
  if (!containerFile) throw new ExtractionError('corrupted_file', 'missing container.xml');
  const containerXml = await reader.readText(containerFile);
  const opfPath = /full-path="([^"]+)"/.exec(containerXml)?.[1];
  if (!opfPath) throw new ExtractionError('corrupted_file', 'opf path not found');

  // 2. Parse the OPF.
  const opfFile = zip.file(opfPath);
  if (!opfFile) throw new ExtractionError('corrupted_file', 'opf file missing');
  const opfXml = await reader.readText(opfFile);
  const opfDir = opfPath.includes('/') ? opfPath.substring(0, opfPath.lastIndexOf('/')) : '';

  const parser = new DOMParser();
  const opfDoc = parser.parseFromString(opfXml, 'application/xml');

  const manifest = new Map<string, string>(); // id → href
  opfDoc.querySelectorAll('manifest > item').forEach((item) => {
    const id = item.getAttribute('id');
    const href = item.getAttribute('href');
    if (id && href) manifest.set(id, href);
  });

  const spineRefs: string[] = [];
  opfDoc.querySelectorAll('spine > itemref').forEach((ref) => {
    const idref = ref.getAttribute('idref');
    if (idref) spineRefs.push(idref);
  });

  // 3. Read the XHTML chapters in spine order.
  const parts: string[] = [];
  for (const idref of spineRefs) {
    const href = manifest.get(idref);
    if (!href) continue;
    const fullPath = opfDir ? `${opfDir}/${href}` : href;
    const entry = zip.file(fullPath);
    if (!entry) continue;
    const xhtml = await reader.readText(entry);
    const xhtmlFile = new File([xhtml], 'chapter.xhtml', { type: 'application/xhtml+xml' });
    const text = (await extractHtmlText(xhtmlFile)).trim();
    if (text) parts.push(text);
  }

  return parts.join('\n\n');
}
