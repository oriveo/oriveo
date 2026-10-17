/**
 * EPUB text extraction (attachment extraction output spec section 10; XML safety in section 15).
 *
 * 1. DRM (encryption other than font obfuscation, rights.xml / license.lcpl / sinf.xml) → `unsupported_format` (`epub_drm`);
 * 2. `META-INF/container.xml` the first `rootfile@full-path` is the OPF;
 * 3. manifest `href` is resolved relative to the OPF, dropping any that escape the package root or start with `/`; zip entries match exactly first, then case-insensitively;
 * 4. read XHTML / HTML chapters in spine order; each chapter is decoded per section 8, has non-void self-closing tags rewritten, then goes through section 8 output;
 * 5. chapters are separated by a blank line, finally normalized per section 3.1.
 *
 * Every entry is read through BoundedArchiveReader; the deadline is checked at the start of each chapter (section 14).
 */

import type JSZipType from 'jszip';
import { ExtractionError } from '../file-text-extractor';
import type { ExtractionDeadline } from '../extraction-deadline';
import { ArchiveEntryLookup, assertArchiveWithinBudget, BoundedArchiveReader } from '../../../utils/zip-budget';
import { decodeHtmlBytes, renderHtmlText } from './html-text-extractor';
import { normalizeStructuredText } from './structured-text';

/** Font obfuscation algorithms do not count as DRM. */
const FONT_OBFUSCATION_ALGORITHMS = new Set([
  'http://www.idpf.org/2008/embedding',
  'http://ns.adobe.com/pdf/enc#RC',
]);

const DRM_MARKER_FILES = ['META-INF/rights.xml', 'META-INF/license.lcpl', 'META-INF/sinf.xml'];

const CHAPTER_MEDIA_TYPES = new Set(['application/xhtml+xml', 'text/html']);

const VOID_ELEMENTS = new Set([
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr',
]);

type Zip = JSZipType;
type ZipEntry = JSZipType.JSZipObject;

export async function extractEpubText(
  file: File,
  deadline?: ExtractionDeadline,
  uiLanguage: string = 'en',
): Promise<string> {
  const JSZip = (await import('jszip')).default;
  let zip: Zip;
  try {
    zip = await JSZip.loadAsync(await file.arrayBuffer());
  } catch (e: unknown) {
    const err = e as { message?: string };
    throw new ExtractionError('corrupted_file', err?.message);
  }
  assertArchiveWithinBudget(zip.files);
  const reader = new BoundedArchiveReader();
  const entries = new ArchiveEntryLookup<ZipEntry>(zip.files);

  // 1. DRM
  if (DRM_MARKER_FILES.some((path) => entries.find(path))) {
    throw new ExtractionError('unsupported_format', 'epub_drm');
  }
  const encryption = entries.find('META-INF/encryption.xml');
  if (encryption && hasDrmEncryption(await reader.readText(encryption))) {
    throw new ExtractionError('unsupported_format', 'epub_drm');
  }

  // 2. OPF path
  const containerEntry = entries.find('META-INF/container.xml');
  if (!containerEntry) throw new ExtractionError('corrupted_file', 'missing container.xml');
  const container = await reader.readXml(containerEntry);
  const opfPath = firstElement(container, 'rootfile')?.getAttribute('full-path');
  if (!opfPath) throw new ExtractionError('corrupted_file', 'opf path not found');

  const opfEntry = entries.find(opfPath);
  if (!opfEntry) throw new ExtractionError('corrupted_file', 'opf file missing');
  const opf = await reader.readXml(opfEntry);

  const manifest = new Map<string, { href: string; mediaType: string }>();
  const manifestElement = firstElement(opf, 'manifest');
  for (const item of manifestElement ? Array.from(manifestElement.getElementsByTagNameNS('*', 'item')) : []) {
    const id = item.getAttribute('id');
    const href = item.getAttribute('href');
    if (id && href !== null) {
      manifest.set(id, { href, mediaType: (item.getAttribute('media-type') ?? '').trim().toLowerCase() });
    }
  }
  const spineElement = firstElement(opf, 'spine');
  const spine = spineElement ? Array.from(spineElement.getElementsByTagNameNS('*', 'itemref')) : [];

  // 3-5. Read chapters in spine order (including linear="no" ones).
  const chapters: string[] = [];
  for (const itemref of spine) {
    deadline?.check();
    const item = manifest.get(itemref.getAttribute('idref') ?? '');
    if (!item || !CHAPTER_MEDIA_TYPES.has(item.mediaType)) continue;
    const path = resolveManifestHref(opfPath, item.href);
    if (path === null) continue;
    const entry = entries.find(path);
    if (!entry) continue;
    const html = rewriteSelfClosingTags(decodeHtmlBytes(await reader.readBytes(entry), uiLanguage));
    const text = renderHtmlText(html);
    if (text) chapters.push(text);
  }
  deadline?.check();

  return normalizeStructuredText(chapters.join('\n\n'));
}

function hasDrmEncryption(xml: string): boolean {
  const pattern = /<(?:[\w.-]+:)?EncryptionMethod\b[^>]*?\bAlgorithm\s*=\s*(["'])(.*?)\1/g;
  for (const match of xml.matchAll(pattern)) {
    if (!FONT_OBFUSCATION_ALGORITHMS.has(match[2].trim())) return true;
  }
  return false;
}

function firstElement(doc: Document | Element, localName: string): Element | null {
  return doc.getElementsByTagNameNS('*', localName)[0] ?? null;
}

/**
 * manifest `href` is resolved relative to the OPF using URL rules: drop everything after `#` / `?`, percent-decode, handle `.` and `..`.
 * Starts with `/`, has a scheme, or has more `..` than directory levels (escapes the package root) → null.
 *
 * Do not use `new URL(href, 'epub:///' + opfPath)` directly: URL rules clamp `..` beyond the root to the root, so out-of-bounds goes undetected.
 */
export function resolveManifestHref(opfPath: string, href: string): string | null {
  const reference = href.split('#')[0].split('?')[0];
  if (reference.startsWith('/') || /^[a-z][a-z0-9+.-]*:/i.test(reference)) return null;
  const segments = opfPath.split('/').slice(0, -1).filter((segment) => segment.length > 0);
  const parts = reference.split('/');
  for (let index = 0; index < parts.length; index++) {
    let segment: string;
    try {
      segment = decodeURIComponent(parts[index]);
    } catch {
      segment = parts[index];
    }
    if (segment === '' || segment === '.') continue;
    if (segment === '..') {
      if (segments.length === 0) return null;
      segments.pop();
      continue;
    }
    segments.push(segment);
  }
  if (segments.length === 0) return null;
  return segments.join('/');
}

/** Rewrite self-closing `<tag .../>` of non-void elements as `<tag ...></tag>`, so `<title/>` and `<script/>` do not swallow the following content. */
export function rewriteSelfClosingTags(html: string): string {
  return html.replace(/<([A-Za-z][^\s/>]*)((?:\s[^<>]*?)?)\s*\/>/g, (whole, tag: string, attributes: string) =>
    VOID_ELEMENTS.has(tag.toLowerCase()) ? whole : `<${tag}${attributes}></${tag}>`);
}
