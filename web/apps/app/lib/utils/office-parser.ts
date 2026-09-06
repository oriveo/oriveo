/**
 * Office file parsing.
 * Uses JSZip to turn DOCX/XLSX/PPTX/ODF into plain text; the import is dynamic so it does not
 * affect first paint. RTF is already plain text and is extracted with regular expressions.
 *
 * Every entry read from the archive goes through BoundedArchiveReader, so a document that declares
 * gigabytes of output cannot exhaust the tab.
 */

import { assertArchiveWithinBudget, BoundedArchiveReader } from './zip-budget';

/** Parse an Office file into plain text */
export async function parseOfficeFile(file: File): Promise<string> {
  const ext = file.name.toLowerCase().split('.').pop() ?? '';

  if (ext === 'rtf') {
    const raw = await file.text();
    // Extract the plain text out of the RTF markup
    return raw
      .replace(/\{\\[^{}]*\}/g, '')           // drop control groups
      .replace(/\\[a-z]+\d*\s?/gi, '')        // drop control words
      .replace(/[{}]/g, '')                    // drop braces
      .replace(/\r\n|\r/g, '\n')
      .trim();
  }

  const JSZip = (await import('jszip')).default;
  const zip = await JSZip.loadAsync(await file.arrayBuffer());
  assertArchiveWithinBudget(zip.files);
  const reader = new BoundedArchiveReader();

  switch (ext) {
    case 'docx': return extractDocxText(zip, reader);
    case 'xlsx': return extractXlsxText(zip, reader);
    case 'pptx': return extractPptxText(zip, reader);
    case 'odt':
    case 'ods':
    case 'odp':  return extractOdfText(zip, reader);
    default:     return '[Unsupported office format]';
  }
}

/** Extract all text content from an XML document */
function xmlTextContent(xml: string): string {
  const parser = new DOMParser();
  const doc = parser.parseFromString(xml, 'application/xml');
  return doc.documentElement.textContent ?? '';
}

/** DOCX: paragraph text from word/document.xml */
async function extractDocxText(zip: any, reader: BoundedArchiveReader): Promise<string> {
  const docXml = zip.file('word/document.xml');
  if (!docXml) return '';
  const xml = await reader.readText(docXml);
    // Insert a newline at every </w:p> to preserve the paragraph structure
  const withBreaks = xml.replace(/<\/w:p>/g, '\n</w:p>');
  return xmlTextContent(withBreaks).replace(/\n{3,}/g, '\n\n').trim();
}

/** XLSX: shared strings plus the data of each sheet */
async function extractXlsxText(zip: any, reader: BoundedArchiveReader): Promise<string> {
  // Read the shared string table
  const ssFile = zip.file('xl/sharedStrings.xml');
  const strings: string[] = [];
  if (ssFile) {
    const ssXml = await reader.readText(ssFile);
    const parser = new DOMParser();
    const doc = parser.parseFromString(ssXml, 'application/xml');
    const siNodes = doc.getElementsByTagName('si');
    for (let i = 0; i < siNodes.length; i++) {
      strings.push(siNodes[i].textContent ?? '');
    }
  }

  // Walk every sheet
  const parts: string[] = [];
  const sheetFiles = Object.keys(zip.files)
    .filter((n: string) => /^xl\/worksheets\/sheet\d+\.xml$/.test(n))
    .sort();

  for (const path of sheetFiles) {
    const sheetXml = await reader.readText(zip.file(path)!);
    const parser = new DOMParser();
    const doc = parser.parseFromString(sheetXml, 'application/xml');
    const rows = doc.getElementsByTagName('row');
    const rowTexts: string[] = [];

    for (let r = 0; r < rows.length; r++) {
      const cells = rows[r].getElementsByTagName('c');
      const cellTexts: string[] = [];
      for (let c = 0; c < cells.length; c++) {
        const cell = cells[c];
        const type = cell.getAttribute('t');
        const vNode = cell.getElementsByTagName('v')[0];
        const val = vNode?.textContent ?? '';
        // type="s" means the value is an index into the shared strings
        cellTexts.push(type === 's' ? (strings[parseInt(val)] ?? val) : val);
      }
      rowTexts.push(cellTexts.join('\t'));
    }
    parts.push(rowTexts.join('\n'));
  }

  return parts.join('\n\n').trim();
}

/** PPTX: text from ppt/slides/slide*.xml */
async function extractPptxText(zip: any, reader: BoundedArchiveReader): Promise<string> {
  const slideFiles = Object.keys(zip.files)
    .filter((n: string) => /^ppt\/slides\/slide\d+\.xml$/.test(n))
    .sort();

  const parts: string[] = [];
  for (const path of slideFiles) {
    const xml = await reader.readText(zip.file(path)!);
    const withBreaks = xml.replace(/<\/a:p>/g, '\n</a:p>');
    const text = xmlTextContent(withBreaks).trim();
    if (text) parts.push(text);
  }
  return parts.join('\n\n').trim();
}

/** ODF (.odt/.ods/.odp): text from content.xml */
async function extractOdfText(zip: any, reader: BoundedArchiveReader): Promise<string> {
  const contentXml = zip.file('content.xml');
  if (!contentXml) return '';
  const xml = await reader.readText(contentXml);
  // Insert a newline at every text:p
  const withBreaks = xml.replace(/<\/text:p>/g, '\n</text:p>');
  return xmlTextContent(withBreaks).replace(/\n{3,}/g, '\n\n').trim();
}
