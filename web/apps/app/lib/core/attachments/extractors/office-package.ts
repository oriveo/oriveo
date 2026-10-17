/**
 * Package access and small DOM helpers shared by the OOXML / ODF extractors (attachment extraction spec sections 4A, 14, 15).
 *
 * - zip entries match exactly first, then case-insensitively (section 4A);
 * - the deadline is checked at the start of every entry read (the "zip entry" loop of section 14);
 * - XML parts are always parsed through `BoundedArchiveReader.readXml`, the only place for the DOCTYPE / parsererror checks (section 15);
 * - OOXML relationship files: `a/b/c.xml` -> `a/b/_rels/c.xml.rels`, a relative Target resolves against the source part's directory (section 4A).
 */

import type JSZipType from 'jszip';
import type { ExtractionDeadline } from '../extraction-deadline';
import { ExtractionError } from '../file-text-extractor';
import { ArchiveEntryLookup, assertArchiveWithinBudget, BoundedArchiveReader } from '../../../utils/zip-budget';

type ZipEntry = JSZipType.JSZipObject;

export type Namespaces = ReadonlySet<string>;

export const namespaces = (...uris: string[]): Namespaces => new Set(uris);

/** markup-compatibility: `mc:AlternateContent` / `mc:Choice` / `mc:Fallback`. */
export const MC = namespaces('http://schemas.openxmlformats.org/markup-compatibility/2006');

/** Namespaces of the relationship id attribute (`r:id`), transitional and strict. */
export const R = namespaces(
  'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
  'http://purl.oclc.org/ooxml/officeDocument/relationships',
);

export function isElement(node: Node | null | undefined): node is Element {
  return !!node && node.nodeType === 1;
}

/** `node` is an element named `local` in one of the namespaces `ns`. */
export function isNamed(node: Node | null | undefined, ns: Namespaces, local: string): boolean {
  return isElement(node) && node.localName === local && ns.has(node.namespaceURI ?? '');
}

export function inNamespace(node: Element, ns: Namespaces): boolean {
  return ns.has(node.namespaceURI ?? '');
}

export function childElements(parent: Element | Document): Element[] {
  const out: Element[] = [];
  for (let child = parent.firstChild; child; child = child.nextSibling) {
    if (isElement(child)) out.push(child);
  }
  return out;
}

export function childNamed(parent: Element | Document, ns: Namespaces, local: string): Element | null {
  for (let child = parent.firstChild; child; child = child.nextSibling) {
    if (isNamed(child, ns, local)) return child as Element;
  }
  return null;
}

export function childrenNamed(parent: Element | Document, ns: Namespaces, local: string): Element[] {
  return childElements(parent).filter((child) => isNamed(child, ns, local));
}

/** The first descendant named `local` in document order. */
export function descendantNamed(parent: Element | Document, ns: Namespaces, local: string): Element | null {
  const list = parent.getElementsByTagNameNS('*', local);
  for (let i = 0; i < list.length; i++) {
    if (ns.has(list[i].namespaceURI ?? '')) return list[i];
  }
  return null;
}

/** A namespaced attribute (`w:val`, `r:id` and the like). */
export function attrNs(element: Element, ns: Namespaces, local: string): string | null {
  for (let i = 0; i < element.attributes.length; i++) {
    const attribute = element.attributes[i];
    if (attribute.localName === local && ns.has(attribute.namespaceURI ?? '')) return attribute.value;
  }
  return null;
}

/** Section 4A: `mc:AlternateContent` follows only the first `mc:Choice`. */
export function firstChoice(alternate: Element): Element | null {
  return childNamed(alternate, MC, 'Choice');
}

export interface Relationship {
  id: string;
  type: string;
  /** Already resolved to a path inside the package (section 4A). */
  target: string;
}

/** Section 4A: the relationship file of part `a/b/c.xml` is `a/b/_rels/c.xml.rels`; the package root uses `_rels/.rels`. */
export function relationshipsPath(part: string): string {
  if (part === '') return '_rels/.rels';
  const slash = part.lastIndexOf('/');
  return `${part.slice(0, slash + 1)}_rels/${part.slice(slash + 1)}.rels`;
}

/** Section 4A: a path starting with `/` is absolute from the package root; a relative one resolves against the source part's directory, handling `.` and `..`. */
export function resolveRelationshipTarget(sourcePart: string, target: string): string {
  const reference = target.split('#')[0];
  const segments = reference.startsWith('/')
    ? []
    : sourcePart.split('/').slice(0, -1).filter((segment) => segment.length > 0);
  for (const raw of reference.split('/')) {
    let segment = raw;
    try {
      segment = decodeURIComponent(raw);
    } catch {
      // Not valid percent-encoding: keep the text as it is.
    }
    if (segment === '' || segment === '.') continue;
    if (segment === '..') {
      segments.pop();
      continue;
    }
    segments.push(segment);
  }
  return segments.join('/');
}

/** An OOXML / ODF package: look up entries, read XML (with the deadline and decompression budget), resolve relationships. */
export class OfficePackage {
  private readonly entries: ArchiveEntryLookup<ZipEntry>;
  private readonly reader = new BoundedArchiveReader();
  private readonly relationshipCache = new Map<string, Relationship[]>();

  private constructor(zip: JSZipType, private readonly deadline?: ExtractionDeadline) {
    this.entries = new ArchiveEntryLookup<ZipEntry>(zip.files);
  }

  /** Opens the zip. When it is not a zip, the raw error JSZip throws goes to the caller to map (the entry point tells encrypted from corrupted by message). */
  static async open(bytes: ArrayBuffer, deadline?: ExtractionDeadline): Promise<OfficePackage> {
    const JSZip = (await import('jszip')).default;
    const zip = await JSZip.loadAsync(bytes);
    // Section 4A: a zip with no entries at all is corrupted (a PPTX has no required main part, so without this check it would produce empty text).
    if (Object.keys(zip.files).length === 0) throw new ExtractionError('corrupted_file', 'empty zip');
    assertArchiveWithinBudget(zip.files);
    return new OfficePackage(zip, deadline);
  }

  get names(): string[] {
    return this.entries.names;
  }

  has(path: string): boolean {
    return this.entries.find(path) !== null;
  }

  /** Reads an XML part; returns null when the entry does not exist. Section 14: the deadline is checked at the start of each zip entry and once more after parsing returns. */
  async xml(path: string): Promise<Document | null> {
    this.deadline?.check();
    const entry = this.entries.find(path);
    if (!entry) return null;
    const doc = await this.reader.readXml(entry);
    this.deadline?.check();
    return doc;
  }

  /** A part that must exist: when missing, throws `corrupted_file`. */
  async requiredXml(path: string): Promise<Document> {
    const doc = await this.xml(path);
    if (!doc) throw new ExtractionError('corrupted_file', `missing ${path}`);
    return doc;
  }

  /** Relationships of a part (those with `TargetMode="External"` are ignored); empty when there is no relationship file. */
  async relationships(part: string): Promise<Relationship[]> {
    const cached = this.relationshipCache.get(part);
    if (cached) return cached;
    const doc = await this.xml(relationshipsPath(part));
    const out: Relationship[] = [];
    if (doc) {
      const list = doc.getElementsByTagNameNS('*', 'Relationship');
      for (let i = 0; i < list.length; i++) {
        const element = list[i];
        if ((element.getAttribute('TargetMode') ?? '').toLowerCase() === 'external') continue;
        const target = element.getAttribute('Target');
        if (!target) continue;
        out.push({
          id: element.getAttribute('Id') ?? '',
          type: element.getAttribute('Type') ?? '',
          target: resolveRelationshipTarget(part, target),
        });
      }
    }
    this.relationshipCache.set(part, out);
    return out;
  }

  /** The first relationship whose Type ends with `typeSuffix` and whose target entry exists; `fallback` when there is none. */
  async relatedPart(sourcePart: string, typeSuffix: string, fallback: string): Promise<string> {
    for (const relationship of await this.relationships(sourcePart)) {
      if (relationship.type.endsWith(typeSuffix) && this.has(relationship.target)) return relationship.target;
    }
    return fallback;
  }
}
