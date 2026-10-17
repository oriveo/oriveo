/**
 * Implementation details beyond the golden fixtures for HTML (section 8), RTF (section 11), EPUB href (section 10), and the deadline (section 14).
 * Details align with the iOS implementation: all three platforms must match byte for byte.
 */
import { describe, expect, it } from 'vitest';
import { ExtractionDeadline } from '../extraction-deadline';
import { ExtractionError } from '../file-text-extractor';
import { decodeHtmlBytes, renderHtmlText } from '../extractors/html-text-extractor';
import { extractRtfText } from '../extractors/rtf-text-extractor';
import { resolveManifestHref, rewriteSelfClosingTags } from '../extractors/epub-text-extractor';

const ascii = (text: string) => Uint8Array.from(text, (ch) => ch.charCodeAt(0));

describe('HTML details (section 8)', () => {
  it('collapsed spaces adjacent across text nodes merge into one', () => {
    expect(renderHtmlText('<p>Visit <a> link</a> now</p>')).toBe('Visit link now');
  });

  it('an li with empty text outputs no line', () => {
    expect(renderHtmlText('<ul><li>A</li><li> </li><li>B</li></ul>')).toBe('- A\n- B');
  });

  it('caption is output as a normal block before the table', () => {
    expect(renderHtmlText('<table><caption>Scores</caption><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>'))
      .toBe('Scores\n\n| A | B |\n| --- | --- |\n| 1 | 2 |');
  });

  it('in tables with merged cells, fully empty rows are dropped', () => {
    expect(renderHtmlText('<table><tr><td colspan="2">Wide</td></tr><tr><td></td><td> </td></tr><tr><td>a</td><td>b</td></tr></table>'))
      .toBe('Wide\na\tb');
  });

  it('an unrecognized meta charset is treated as undeclared (falls back to section 4 detection)', () => {
    const bytes = new Uint8Array([...ascii('<meta charset="x-unknown"><p>'), 0xd6, 0xd0, 0xce, 0xc4, ...ascii('</p>')]);
    expect(renderHtmlText(decodeHtmlBytes(bytes, 'zh-Hans'))).toBe('\u4E2D\u6587');
  });

  it('meta charset accepts the section 4 candidate target name itself (windows-1251)', () => {
    // Section 4 detection would decode these bytes as GBK (U+4E2D U+6587); with windows-1251 declared, the declaration wins.
    const bytes = new Uint8Array([...ascii('<meta charset="windows-1251"><p>'), 0xd6, 0xd0, 0xce, 0xc4, ...ascii('</p>')]);
    expect(renderHtmlText(decodeHtmlBytes(bytes, 'zh-Hans'))).toBe('ЦРОД');
  });

  it('legacy entities without a semicolon are still decoded', () => {
    expect(renderHtmlText('<p>&copy 2026 &lt;x&gt; &amp more</p>')).toBe('© 2026 <x> & more');
  });

  it('the list item marker goes before the first text; br inside li outputs a space', () => {
    expect(renderHtmlText('<ul><li><p>a</p></li><li>b<br>c</li></ul>')).toBe('- a\n\n- b c');
  });

  it('when flattening a nested table in a cell, empty cells and empty rows are kept', () => {
    expect(renderHtmlText(
      '<table><tr><th>H</th><th>K</th></tr><tr><td>x</td><td><table>'
        + '<tr><td>a</td><td></td><td>c</td></tr><tr></tr><tr><td>d</td><td> </td><td>f</td></tr></table></td></tr></table>',
    )).toBe('| H | K |\n| --- | --- |\n| x | a; ; c /  / d; ; f |');
  });

  it('in a cell: block-level line breaks become <br> (consecutive ones merge, leading and trailing ones are removed), headings get no #, nested tables are flattened', () => {
    expect(renderHtmlText(
      '<table><tr><th>H</th><th>K</th></tr><tr><td><div></div><h2>T</h2><div><p>p</p></div></td>'
        + '<td><table><tr><td><p>a1</p><p>a2</p></td><td>b</td></tr></table></td></tr></table>',
    )).toBe('| H | K |\n| --- | --- |\n| T<br>p | a1 a2; b |');
  });
});

describe('RTF details (section 11)', () => {
  it('when \\f never appeared, the current font is \\deff', () => {
    const rtf = String.raw`{\rtf1\ansi\ansicpg1252\deff1{\fonttbl{\f0 Arial;}{\f1\fcharset134 SimSun;}}\pard \'d6\'d0\par}`;
    expect(extractRtfText(ascii(rtf))).toBe('\u4E2D');
  });

  it('when a double-byte code page run fails to decode as a whole, decode unit by unit; each failed unit yields one U+FFFD', () => {
    const rtf = String.raw`{\rtf1\ansi\ansicpg936 \'d6\'d0\'ff\'d6\'d0\par}`;
    expect(extractRtfText(ascii(rtf))).toBe('\u4E2D\uFFFD\u4E2D');
  });

  it('a lone surrogate yields U+FFFD', () => {
    expect(extractRtfText(ascii(String.raw`{\rtf1 A\u-10179?B\par}`))).toBe('A�B');
  });

  it('while \\v hides text, line breaks such as \\par are not output either', () => {
    expect(extractRtfText(ascii(String.raw`{\rtf1 A\v hidden\par more\line\v0 B\par}`))).toBe('AB');
  });

  it('\\*\\ud is allowed only inside a \\upr group', () => {
    expect(extractRtfText(ascii(String.raw`{\rtf1 {\*\ud hidden}A\par}`))).toBe('A');
    expect(extractRtfText(ascii(String.raw`{\rtf1 {\upr{ansi}{\*\ud uni}}\par}`))).toBe('uni');
  });

  it('an unknown code page is decoded as 1252', () => {
    expect(extractRtfText(ascii(String.raw`{\rtf1\ansi\ansicpg9999 caf\'e9\par}`))).toBe('café');
  });

  it('deadline already passed: reports extraction_timeout in the first round', () => {
    let now = 0;
    const deadline = new ExtractionDeadline(() => now, 10);
    now = 10;
    const failure = (() => {
      try {
        extractRtfText(ascii(String.raw`{\rtf1 A}`), deadline);
        return null;
      } catch (e) {
        return e;
      }
    })();
    expect(failure).toBeInstanceOf(ExtractionError);
    expect((failure as ExtractionError).code).toBe('extraction_timeout');
  });
});

describe('EPUB details (section 10)', () => {
  it('href resolves relative to the OPF: strip #, percent-decode, drop out-of-bounds and absolute paths', () => {
    expect(resolveManifestHref('OEBPS/content.opf', '../Text/Chapter%20Two.xhtml#start')).toBe('Text/Chapter Two.xhtml');
    expect(resolveManifestHref('OEBPS/content.opf', './a/../b.xhtml')).toBe('OEBPS/b.xhtml');
    expect(resolveManifestHref('OEBPS/content.opf', '../../outside.xhtml')).toBeNull();
    expect(resolveManifestHref('OEBPS/content.opf', '/Text/abs.xhtml')).toBeNull();
    expect(resolveManifestHref('content.opf', 'ch1.xhtml')).toBe('ch1.xhtml');
    // Out-of-bounds is decided while handling `..` segment by segment: URL parsing would clamp extra `..` to the root, which must not happen here.
    expect(resolveManifestHref('content.opf', 'a/../../ch1.xhtml')).toBeNull();
    expect(resolveManifestHref('OEBPS/content.opf', 'Text/../../../ch1.xhtml')).toBeNull();
  });

  it('self-closing non-void elements are rewritten as paired tags; void elements are untouched', () => {
    expect(rewriteSelfClosingTags('<title/><script src="a.js"/><br/><meta charset="utf-8"/>'))
      .toBe('<title></title><script src="a.js"></script><br/><meta charset="utf-8"/>');
  });
});
