/**
 * PPTX text extraction (attachment extraction output spec section 7; blocks and tables per sections 3.2 / 3.3, finally normalized per section 3.1).
 */

import type { ExtractionDeadline } from '../extraction-deadline';
import type { Namespaces, OfficePackage } from './office-package';
import { MC, R, attrNs, childElements, childNamed, childrenNamed, firstChoice, isNamed, namespaces } from './office-package';
import {
  formatTableCell,
  joinBlocks,
  normalizeStructuredText,
  paragraphBlock,
  spacedBlock,
  tableBlocks,
  type TextBlock,
} from './structured-text';

const P: Namespaces = namespaces(
  'http://schemas.openxmlformats.org/presentationml/2006/main',
  'http://purl.oclc.org/ooxml/presentationml/main',
);
const A: Namespaces = namespaces(
  'http://schemas.openxmlformats.org/drawingml/2006/main',
  'http://purl.oclc.org/ooxml/drawingml/main',
);

const TITLE_TYPES = new Set(['title', 'ctrTitle']);
const SKIPPED_PLACEHOLDERS = new Set(['sldNum', 'dt', 'ftr', 'hdr', 'sldImg']);

export async function extractPptxText(pkg: OfficePackage, deadline?: ExtractionDeadline): Promise<string> {
  const blocks: TextBlock[] = [];
  const slides = await slideParts(pkg);
  for (let index = 0; index < slides.length; index++) {
    deadline?.check();
    const slidePath = slides[index];
    const doc = await pkg.xml(slidePath);
    if (!doc?.documentElement) continue;
    blocks.push(...await slideBlocks(pkg, slidePath, doc.documentElement, index + 1));
  }
  deadline?.check();
  return normalizeStructuredText(joinBlocks(blocks));
}

/** Slide order: `p:sldIdLst` of presentation.xml; if presentation.xml is missing, ascending N of `ppt/slides/slideN.xml`. */
async function slideParts(pkg: OfficePackage): Promise<string[]> {
  const presentationPath = await pkg.relatedPart('', '/officeDocument', 'ppt/presentation.xml');
  const presentation = await pkg.xml(presentationPath);
  if (presentation?.documentElement) {
    const relationships = new Map((await pkg.relationships(presentationPath)).map((rel) => [rel.id, rel.target]));
    const list = childNamed(presentation.documentElement, P, 'sldIdLst');
    return (list ? childrenNamed(list, P, 'sldId') : [])
      .map((slide) => relationships.get(attrNs(slide, R, 'id') ?? ''))
      .filter((target): target is string => target !== undefined && pkg.has(target));
  }
  return pkg.names
    .map((name) => ({ name, match: /^ppt\/slides\/slide(\d+)\.xml$/i.exec(name) }))
    .filter((entry): entry is { name: string; match: RegExpExecArray } => entry.match !== null)
    .sort((a, b) => Number(a.match[1]) - Number(b.match[1]))
    .map((entry) => entry.name);
}

async function slideBlocks(pkg: OfficePackage, slidePath: string, slide: Element, number: number): Promise<TextBlock[]> {
  const tree = shapeTree(slide);
  const titleShape = tree ? findTitleShape(tree) : null;
  const title = titleShape
    ? shapeParagraphs(titleShape).join(' ').replace(/\n/g, ' ').trim()
    : '';
  const show = (slide.getAttribute('show') ?? '').toLowerCase();
  const hidden = show === '0' || show === 'false';

  const blocks: TextBlock[] = [spacedBlock(`## Slide ${number}${title ? `: ${title}` : ''}${hidden ? ' (hidden)' : ''}`)];
  if (tree) walkShapes(tree, titleShape, blocks);

  const notesRelationship = (await pkg.relationships(slidePath)).find((rel) => rel.type.endsWith('/notesSlide'));
  const notes = notesRelationship ? await pkg.xml(notesRelationship.target) : null;
  const notesTree = notes?.documentElement ? shapeTree(notes.documentElement) : null;
  if (notesTree) {
    const paragraphs: TextBlock[] = [];
    for (const shape of shapesInOrder(notesTree)) {
      if (placeholderType(shape) !== 'body') continue;
      for (const text of shapeParagraphs(shape)) {
        const block = paragraphBlock(text);
        if (block) paragraphs.push(block);
      }
    }
    if (paragraphs.length > 0) blocks.push(spacedBlock('### Notes'), ...paragraphs);
  }
  return blocks;
}

function shapeTree(root: Element): Element | null {
  const commonData = childNamed(root, P, 'cSld');
  return commonData ? childNamed(commonData, P, 'spTree') : null;
}

/** All `p:sp` in the shape tree in document order (descends into `p:grpSp`; `mc:AlternateContent` follows only the first `mc:Choice`). */
function shapesInOrder(container: Element): Element[] {
  const out: Element[] = [];
  for (const child of childElements(container)) {
    if (isNamed(child, P, 'sp')) out.push(child);
    else if (isNamed(child, P, 'grpSp')) out.push(...shapesInOrder(child));
    else if (isNamed(child, MC, 'AlternateContent')) {
      const choice = firstChoice(child);
      if (choice) out.push(...shapesInOrder(choice));
    }
  }
  return out;
}

function findTitleShape(tree: Element): Element | null {
  return shapesInOrder(tree).find((shape) => TITLE_TYPES.has(placeholderType(shape) ?? '')) ?? null;
}

/** `p:nvSpPr/p:nvPr/p:ph@type`(`p:graphicFrame` uses `p:nvGraphicFramePr`); returns null if not a placeholder. */
function placeholderType(shape: Element): string | null {
  const nonVisual = childElements(shape).find((child) => P.has(child.namespaceURI ?? '') && child.localName.startsWith('nv'));
  const properties = nonVisual ? childNamed(nonVisual, P, 'nvPr') : null;
  const placeholder = properties ? childNamed(properties, P, 'ph') : null;
  if (!placeholder) return null;
  return placeholder.getAttribute('type') ?? 'obj';
}

function walkShapes(container: Element, titleShape: Element | null, blocks: TextBlock[]): void {
  for (const child of childElements(container)) {
    if (isNamed(child, P, 'sp')) {
      if (child === titleShape || SKIPPED_PLACEHOLDERS.has(placeholderType(child) ?? '')) continue;
      for (const text of shapeParagraphs(child)) {
        const block = paragraphBlock(text);
        if (block) blocks.push(block);
      }
    } else if (isNamed(child, P, 'grpSp')) {
      walkShapes(child, titleShape, blocks);
    } else if (isNamed(child, P, 'graphicFrame')) {
      if (SKIPPED_PLACEHOLDERS.has(placeholderType(child) ?? '')) continue;
      const table = child.getElementsByTagNameNS('*', 'tbl');
      for (let i = 0; i < table.length; i++) {
        if (A.has(table[i].namespaceURI ?? '')) {
          blocks.push(...tableBlocks(tableRows(table[i])));
          break;
        }
      }
    } else if (isNamed(child, MC, 'AlternateContent')) {
      const choice = firstChoice(child);
      if (choice) walkShapes(choice, titleShape, blocks);
    }
  }
}

/** Text of each `a:p` in the `p:txBody` of a `p:sp`. */
function shapeParagraphs(shape: Element): string[] {
  const body = childNamed(shape, P, 'txBody');
  return body ? textBodyParagraphs(body) : [];
}

function textBodyParagraphs(body: Element): string[] {
  return childrenNamed(body, A, 'p').map(paragraphText);
}

/** Paragraph text: `a:r/a:t` and `a:fld/a:t`; `a:br` → `\n`. */
function paragraphText(paragraph: Element): string {
  let out = '';
  for (const child of childElements(paragraph)) {
    if (isNamed(child, A, 'r') || isNamed(child, A, 'fld')) {
      const text = childNamed(child, A, 't');
      if (text) out += text.textContent ?? '';
    } else if (isNamed(child, A, 'br')) {
      out += '\n';
    }
  }
  return out;
}

function tableRows(table: Element): string[][] {
  return childrenNamed(table, A, 'tr').map((row) => childrenNamed(row, A, 'tc').map((cell) => {
    if (isTrue(cell.getAttribute('hMerge')) || isTrue(cell.getAttribute('vMerge'))) return '';
    const body = childNamed(cell, A, 'txBody');
    return formatTableCell(body ? textBodyParagraphs(body) : []);
  }));
}

function isTrue(value: string | null): boolean {
  return value === '1' || value?.toLowerCase() === 'true';
}
