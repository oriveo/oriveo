import { describe, expect, it } from 'vitest';
import { extractSelectionMarkdown } from '../selection-source';

const TABLE_SOURCE = `Yes, my English rewrite keeps the same meaning as your draft. I matched it line by line:

| Draft | Polished |
|------|------|
| my hometown is a small pretty place | My hometown is a beautiful little place |
| there are clean rivers there | There are clear rivers |
| flowers open up in spring | In spring flowers bloom |
| trees grow thick in summer | In summer trees grow lush |

If you like, I can polish the rest too.`;

describe('extractSelectionMarkdown', () => {
  it('maps a flattened rendered table selection back to the raw markdown table', () => {
    const renderedSelection =
      'Draft Polished my hometown is a small pretty place My hometown is a beautiful little place there are clean rivers there There are clear rivers flowers open up in spring In spring flowers bloom trees grow thick in summer In summer trees grow lush';

    const result = extractSelectionMarkdown(TABLE_SOURCE, renderedSelection);
    expect(result).not.toBeNull();
    expect(result).toContain('| Draft | Polished |');
    expect(result).toContain('|------|------|');
    expect(result).toContain('| my hometown is a small pretty place | My hometown is a beautiful little place |');
    expect(result).not.toContain('If you like');
  });

  it('only keeps the selected rows (+ header) when a subset of a long table is selected', () => {
    // A 4-row table with only rows 2 and 3 selected returns just those rows plus the header and separator rows, not rows 1 and 4
    const renderedSelection = 'there are clean rivers there There are clear rivers flowers open up in spring In spring flowers bloom';
    const result = extractSelectionMarkdown(TABLE_SOURCE, renderedSelection);
    expect(result).not.toBeNull();
    // The header and separator rows are always added back so the table stays valid
    expect(result).toContain('| Draft | Polished |');
    expect(result).toContain('|------|------|');
    // The two selected rows are present
    expect(result).toContain('| there are clean rivers there | There are clear rivers |');
    expect(result).toContain('| flowers open up in spring | In spring flowers bloom |');
    // The unselected rows are not
    expect(result).not.toContain('my hometown is a small pretty place');
    expect(result).not.toContain('trees grow thick in summer');
  });

  it('keeps only the selected list items', () => {
    const source = 'You could write:\n\n- Introduce yourself\n- My hometown\n- My teacher\n- An unforgettable day\n\nPick one.';
    const rendered = 'My hometown My teacher';
    const result = extractSelectionMarkdown(source, rendered);
    expect(result).toBe('- My hometown\n- My teacher');
  });

  it('keeps a fenced code block whole even when only part is selected', () => {
    const source = 'For example:\n\n```ts\nconst alpha = 1;\nconst beta = 2;\nconst gamma = 3;\n```\n\nThat is all.';
    const rendered = 'const beta = 2; const gamma = 3;';
    const result = extractSelectionMarkdown(source, rendered);
    expect(result).not.toBeNull();
    expect(result).toContain('```ts');
    expect(result).toContain('const alpha = 1;');
    expect(result).toContain('const gamma = 3;');
  });

  it('returns null for a plain-paragraph selection (rendered text already faithful)', () => {
    const source = 'This is an ordinary paragraph with no structure at all.\n\nThe second paragraph is plain text too.';
    const rendered = 'This is an ordinary paragraph with no structure at all.';
    expect(extractSelectionMarkdown(source, rendered)).toBeNull();
  });

  it('returns null when the selection does not match the source', () => {
    expect(extractSelectionMarkdown(TABLE_SOURCE, 'a completely unrelated piece of text')).toBeNull();
  });

  it('returns null for selections too short to match confidently', () => {
    expect(extractSelectionMarkdown(TABLE_SOURCE, 'Draft')).toBeNull();
  });
});

describe('extractSelectionMarkdown math structure', () => {
  const MATH_SOURCE = `Intro paragraph here.

$$
tan(30) = \\frac{height}{100}
$$

Outro paragraph.`;

  it('treats block math as structure and returns raw $$ source', () => {
    // The selection text carries the formula source (restored from the KaTeX annotation), so its signature can be matched against the source
    const result = extractSelectionMarkdown(MATH_SOURCE, '$$tan(30) = \\frac{height}{100}$$');
    expect(result).not.toBeNull();
    expect(result).toContain('$$');
    expect(result).toContain('\\frac{height}{100}');
  });

  it('treats inline math as structure and returns the source line', () => {
    const source = 'The value $x_1$ matters in physics today.\n\nAnother paragraph.';
    const result = extractSelectionMarkdown(source, 'value $x_1$ matters in physics');
    expect(result).toBe('The value $x_1$ matters in physics today.');
  });
});
