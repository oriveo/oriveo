import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

// In RTL, left:-9999px stretches the document by about 10k px of horizontal scroll, and on phone widths the whole page scrolls away to blank.
describe('skip link is visually hidden without negative offsets', () => {
  it('layout sr-skip is hidden by clipping and never uses negative left/right values', () => {
    const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'layout.tsx'), 'utf8');
    const anchor = src.slice(src.indexOf('className="sr-skip"'), src.indexOf('Skip to content'));
    expect(anchor).toContain("clipPath: 'inset(50%)'");
    expect(anchor).not.toMatch(/(left|right|insetInline\w*):\s*'-/);
  });
});
