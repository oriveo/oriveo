/**
 * Edge cases for OOXML / ODF / EPUB beyond the shared golden fixtures (attachment extraction output spec sections 3.3, 4A, 5, 7, 9).
 * Each case builds a minimal package in memory, runs it through the production entry FileTextExtractor.extract and compares the output byte for byte.
 */
import JSZip from 'jszip';
import { describe, expect, it, vi } from 'vitest';
import { DEFAULT_LIMITS, ExtractionError, FileTextExtractor } from '../file-text-extractor';
import { formatTableCell } from '../extractors/structured-text';

vi.mock('../../telemetry', () => ({ trackEvent: vi.fn() }));

const MIME = {
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  odt: 'application/vnd.oasis.opendocument.text',
  ods: 'application/vnd.oasis.opendocument.spreadsheet',
  epub: 'application/epub+zip',
} as const;

const W_NS = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const S_NS = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const P_NS = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const A_NS = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const R_NS = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const REL_NS = 'http://schemas.openxmlformats.org/package/2006/relationships';
const ODF_NS = [
  'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"',
  'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"',
  'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"',
].join(' ');

async function packageFile(name: string, mime: string, parts: Record<string, string>): Promise<File> {
  const zip = new JSZip();
  for (const [path, content] of Object.entries(parts)) zip.file(path, content);
  const bytes = await zip.generateAsync({ type: 'uint8array' });
  return new File([bytes], name, { type: mime });
}

function relationships(...entries: [id: string, type: string, target: string][]): string {
  return `<Relationships xmlns="${REL_NS}">${entries
    .map(([id, type, target]) => `<Relationship Id="${id}" Type="${R_NS}/${type}" Target="${target}"/>`)
    .join('')}</Relationships>`;
}

const extract = (file: File) => FileTextExtractor.extract(file, DEFAULT_LIMITS, 'file', 'en');

async function extractError(file: File): Promise<string | null> {
  const failure = await extract(file).then(() => null, (e: unknown) => e);
  expect(failure).toBeInstanceOf(ExtractionError);
  return (failure as ExtractionError).code;
}

describe('§3.3 cell text', () => {
  it('each paragraph is trimmed first (including \\r \\n), empty paragraphs are dropped, then joined with <br>', () => {
    expect(formatTableCell([' a\r\n', '\r\n', '\tb\tc|d '])).toBe('a<br>b c\\|d');
  });

  it('XLSX single-value cell is trimmed before conversion: a trailing _x000D_ leaves no <br>', async () => {
    const file = await packageFile('cells.xlsx', MIME.xlsx, {
      'xl/workbook.xml': `<workbook xmlns="${S_NS}" xmlns:r="${R_NS}"><sheets><sheet name="S1" sheetId="1" r:id="rId1"/></sheets></workbook>`,
      'xl/_rels/workbook.xml.rels': relationships(['rId1', 'worksheet', 'worksheets/sheet1.xml']),
      'xl/worksheets/sheet1.xml': `<worksheet xmlns="${S_NS}"><sheetData><row r="1">`
        + '<c r="A1" t="inlineStr"><is><t>x_x000D_</t></is></c><c r="B1" t="inlineStr"><is><t>y</t></is></c>'
        + '</row></sheetData></worksheet>',
    });
    expect((await extract(file)).content).toBe('## Sheet: S1\n\n| x | y |\n| --- | --- |');
  });

  it('ODS single-value cell without text:p is trimmed before conversion', async () => {
    const file = await packageFile('cells.ods', MIME.ods, {
      'content.xml': `<office:document-content ${ODF_NS}><office:body><office:spreadsheet>`
        + '<table:table table:name="S"><table:table-row>'
        + '<table:table-cell office:string-value=" v&#10;"/><table:table-cell><text:p>w</text:p></table:table-cell>'
        + '</table:table-row></table:table></office:spreadsheet></office:body></office:document-content>',
    });
    expect((await extract(file)).content).toBe('## Sheet: S\n\n| v | w |\n| --- | --- |');
  });

  it('ODT nested table flattening: multiple paragraphs of an inner cell are joined with one space', async () => {
    const file = await packageFile('nested.odt', MIME.odt, {
      'content.xml': `<office:document-content ${ODF_NS}><office:body><office:text><table:table><table:table-row>`
        + '<table:table-cell><text:p>Left</text:p></table:table-cell>'
        + '<table:table-cell><table:table><table:table-row>'
        + '<table:table-cell><text:p>a1</text:p><text:p>a2</text:p></table:table-cell>'
        + '<table:table-cell><text:p>b</text:p></table:table-cell>'
        + '</table:table-row></table:table></table:table-cell>'
        + '</table:table-row></table:table></office:text></office:body></office:document-content>',
    });
    expect((await extract(file)).content).toBe('| Left | a1 a2; b |\n| --- | --- |');
  });
});

describe('§4A unopenable means corrupted', () => {
  it.each([
    ['empty.pptx', MIME.pptx],
    ['empty.xlsx', MIME.xlsx],
    ['empty.odt', MIME.odt],
    ['empty.epub', MIME.epub],
  ])('empty zip: %s → corrupted_file', async (name, mime) => {
    expect(await extractError(await packageFile(name, mime, {}))).toBe('corrupted_file');
  });

  it('XLSX missing workbook → corrupted_file', async () => {
    const file = await packageFile('no-workbook.xlsx', MIME.xlsx, { 'docProps/app.xml': '<Properties/>' });
    expect(await extractError(file)).toBe('corrupted_file');
  });

  it('EPUB missing container.xml or OPF → corrupted_file', async () => {
    const noContainer = await packageFile('no-container.epub', MIME.epub, { mimetype: 'application/epub+zip' });
    expect(await extractError(noContainer)).toBe('corrupted_file');
    const noOpf = await packageFile('no-opf.epub', MIME.epub, {
      'META-INF/container.xml': '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
        + '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    });
    expect(await extractError(noOpf)).toBe('corrupted_file');
  });
});

describe('§5 DOCX field "instruction" state', () => {
  it('during the instruction state, tabs, line breaks, non-breaking hyphens, note references and text boxes are not taken', async () => {
    const run = (inner: string) => `<w:r>${inner}</w:r>`;
    const file = await packageFile('field.docx', MIME.docx, {
      'word/document.xml': `<w:document xmlns:w="${W_NS}" xmlns:v="urn:schemas-microsoft-com:vml"><w:body><w:p>`
        + run('<w:t>A</w:t>')
        + run('<w:fldChar w:fldCharType="begin"/>')
        + run('<w:instrText>HYPERLINK "x"</w:instrText>')
        + run('<w:tab/><w:br/><w:cr/><w:noBreakHyphen/><w:footnoteReference w:id="1"/><w:endnoteReference w:id="2"/><w:t>x</w:t>')
        + run('<w:pict><v:textbox><w:txbxContent><w:p><w:r><w:t>Box</w:t></w:r></w:p></w:txbxContent></v:textbox></w:pict>')
        + run('<w:fldChar w:fldCharType="separate"/>')
        + run('<w:t>B</w:t>')
        + run('<w:fldChar w:fldCharType="end"/>')
        + '</w:p></w:body></w:document>',
      'word/footnotes.xml': `<w:footnotes xmlns:w="${W_NS}"><w:footnote w:id="1"><w:p><w:r><w:t>Note</w:t></w:r></w:p></w:footnote></w:footnotes>`,
      'word/endnotes.xml': `<w:endnotes xmlns:w="${W_NS}"><w:endnote w:id="2"><w:p><w:r><w:t>End</w:t></w:r></w:p></w:endnote></w:endnotes>`,
    });
    expect((await extract(file)).content).toBe('AB');
  });
});

describe('§7 PPTX slide references', () => {
  it('entries in sldIdLst whose relationship cannot be resolved are skipped and take no number', async () => {
    const slide = (title: string) => `<p:sld xmlns:p="${P_NS}" xmlns:a="${A_NS}"><p:cSld><p:spTree>`
      + '<p:sp><p:nvSpPr><p:cNvPr id="2" name="T"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
      + `<p:txBody><a:p><a:r><a:t>${title}</a:t></a:r></a:p></p:txBody></p:sp>`
      + '</p:spTree></p:cSld></p:sld>';
    const file = await packageFile('unresolved.pptx', MIME.pptx, {
      'ppt/presentation.xml': `<p:presentation xmlns:p="${P_NS}" xmlns:r="${R_NS}"><p:sldIdLst>`
        + '<p:sldId id="256" r:id="rId9"/><p:sldId id="257" r:id="rId1"/><p:sldId id="258" r:id="rId2"/>'
        + '</p:sldIdLst></p:presentation>',
      'ppt/_rels/presentation.xml.rels': relationships(
        ['rId1', 'slide', 'slides/slide1.xml'],
        ['rId2', 'slide', 'slides/slide2.xml'],
      ),
      'ppt/slides/slide1.xml': slide('First'),
      'ppt/slides/slide2.xml': slide('Second'),
    });
    expect((await extract(file)).content).toBe('## Slide 1: First\n\n## Slide 2: Second');
  });
});

describe('§9 ODT table repeats and covered cells', () => {
  it('not trimmed to the used range: leading empty rows and columns are kept, trailing empty repeats are not expanded', async () => {
    const file = await packageFile('range.odt', MIME.odt, {
      'content.xml': `<office:document-content ${ODF_NS}><office:body><office:text><table:table>`
        + '<table:table-row><table:table-cell table:number-columns-repeated="3"/></table:table-row>'
        + '<table:table-row><table:table-cell/><table:covered-table-cell/>'
        + '<table:table-cell><text:p>A</text:p></table:table-cell>'
        + '<table:table-cell table:number-columns-repeated="1000"/></table:table-row>'
        + '<table:table-row table:number-rows-repeated="1000"><table:table-cell/></table:table-row>'
        + '</table:table></office:text></office:body></office:document-content>',
    });
    expect((await extract(file)).content).toBe('|  |  |  |\n| --- | --- | --- |\n|  |  | A |');
  });

  it('empty rows in the middle are not merged and output line by line; one run of empty repeated rows yields at most 100 rows', async () => {
    const odt = (rows: string) => packageFile('rows.odt', MIME.odt, {
      'content.xml': `<office:document-content ${ODF_NS}><office:body><office:text><table:table>${rows}`
        + '</table:table></office:text></office:body></office:document-content>',
    });
    const row = (text: string) => `<table:table-row><table:table-cell><text:p>${text}</text:p></table:table-cell>`
      + '<table:table-cell><text:p>.</text:p></table:table-cell></table:table-row>';
    const empty = (repeat: number) => `<table:table-row table:number-rows-repeated="${repeat}"><table:table-cell/></table:table-row>`;
    const twoBlank = await extract(await odt(row('A') + empty(1) + empty(1) + row('B')));
    expect(twoBlank.content).toBe('| A | . |\n| --- | --- |\n|  |  |\n|  |  |\n| B | . |');
    const many = await extract(await odt(row('A') + empty(150) + row('B')));
    expect(many.content.split('\n').filter((line) => line === '|  |  |')).toHaveLength(100);
  });

  it('beyond 50 columns only the first 50 are drawn, and N is computed in full from the repeat count', async () => {
    const file = await packageFile('wide.odt', MIME.odt, {
      'content.xml': `<office:document-content ${ODF_NS}><office:body><office:text><table:table><table:table-row>`
        + '<table:table-cell table:number-columns-repeated="60"><text:p>x</text:p></table:table-cell>'
        + '<table:table-cell table:number-columns-repeated="5"/>'
        + '<table:table-cell><text:p>z</text:p></table:table-cell>'
        + '</table:table-row></table:table></office:text></office:body></office:document-content>',
    });
    const content = (await extract(file)).content;
    expect(content.split('\n')[0]).toBe(`| ${Array.from({ length: 50 }, () => 'x').join(' | ')} |`);
    expect(content.endsWith('\n\n(16 more columns not shown)')).toBe(true);
  });
});
