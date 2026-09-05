/**
 * Normalizes LaTeX-style delimiters to the markdown standard (dollar form) so downstream remark-math recognizes them.
 *
 *   inline (single line): \(text\) -> $text$
 *   block (may span lines): \[text\] -> $$text$$
 *
 * Masking rules (order matters):
 *   1. Mask fenced code blocks first (``` or ~~~) with placeholders
 *   2. Then mask inline code (`...`)
 *   3. Replace \[...\] -> $$...$$ (block level first)
 *   4. Replace \(...\) -> $...$
 *   5. Restore the placeholders
 *
 * Indented code blocks (4 spaces) are not masked: expensive to detect and rarely collide with LaTeX.
 */

const PLACEHOLDER_PREFIX = '\u0000LATEXGUARD';
const PLACEHOLDER_SUFFIX = '\u0001';

function makePlaceholder(idx: number): string {
  return `${PLACEHOLDER_PREFIX}${idx}${PLACEHOLDER_SUFFIX}`;
}

/**
 * Masks fenced code blocks and inline code with placeholders; returns the masked text and a restore table.
 * Fenced blocks win (opening and closing fences must use the same character, at least 3 long).
 */
function maskCodeRegions(text: string): { masked: string; restore: string[] } {
  const restore: string[] = [];

  // Step 1: fenced code block: ``` or ~~~, matching fence characters, length >=3
  // (^|\n) anchors the line start, then an optional indent plus the fence; the close uses the same character and length
  const fencedRe = /(^|\n)([ \t]{0,3})(`{3,}|~{3,})([^\n]*)\n([\s\S]*?)(?:\n[ \t]{0,3}\3[ \t]*(?=\n|$)|$)/g;
  let masked = text.replace(fencedRe, (match) => {
    const idx = restore.length;
    restore.push(match);
    return makePlaceholder(idx);
  });

  // Step 2: inline code: backtick pairs, including multi-backtick delimiters `code` / ``code with ` ``
  // Simplification: only single or multi backtick pairs, never across lines.
  const inlineCodeRe = /(`+)([^`\n]|[^`\n]*?[^`\n])\1/g;
  masked = masked.replace(inlineCodeRe, (match) => {
    const idx = restore.length;
    restore.push(match);
    return makePlaceholder(idx);
  });

  return { masked, restore };
}

function unmask(text: string, restore: string[]): string {
  if (restore.length === 0) return text;
  // Placeholders look like \u0000LATEXGUARD{idx}\u0001
  return text.replace(/\u0000LATEXGUARD(\d+)\u0001/g, (_, idx) => restore[Number(idx)] ?? '');
}

/**
 * Replaces block-level \[...\] -> $$...$$ (may span lines).
 *
 * Note: in a JS replace replacement string `$$` means a literal `$`, which the function form avoids.
 */
function replaceBlockDelimiters(text: string): string {
  // [\s\S] spans lines; non-greedy so it does not swallow the next block
  // Boundary rule: \[ pairs directly with \], and the content must not contain \[ or \]
  return text.replace(/\\\[([\s\S]+?)\\\]/g, (_, inner) => `$$${inner}$$`);
}

/**
 * Replaces inline \(...\) -> $...$ (must not span lines).
 *
 * [^\n]+? keeps it on one line
 */
function replaceInlineDelimiters(text: string): string {
  return text.replace(/\\\(([^\n]+?)\\\)/g, (_, inner) => `$${inner}$`);
}

/**
 * Entry point: normalize LaTeX delimiters.
 */
export function normalizeLatexDelimiters(text: string): string {
  if (!text || typeof text !== 'string') return text;
  // Short circuit: with no \( or \[ at all, return early instead of running the regexes
  if (text.indexOf('\\(') === -1 && text.indexOf('\\[') === -1) return text;

  const { masked, restore } = maskCodeRegions(text);
  // Block level first, since \[ / \] never overlaps \( / \)
  const withBlock = replaceBlockDelimiters(masked);
  const withInline = replaceInlineDelimiters(withBlock);
  return unmask(withInline, restore);
}

/**
 * Streaming strategy: find the last unclosed LaTeX delimiter and split everything from it to the end
 * off as a plain-text tail, applying preprocessing and rendering only to the closed part. This keeps
 * half-finished formulas from flickering.
 *
 * Supported opening delimiters: `\(` / `\[` / `$$` / a lone `$`
 *
 * Approach: scan left to right with a state machine, tracking whether the cursor is inside fenced code,
 * inline code or math. Still being in a math opening at the end of the scan means the tail is unclosed.
 */
export function splitClosedAndOpenLatex(text: string): { closed: string; tail: string } {
  if (!text) return { closed: text, tail: '' };

  let i = 0;
  const len = text.length;
  // Last known closed boundary (the opening position doubles as the fallback split point)
  let lastOpenStart = -1;
  type Mode = 'normal' | 'fencedCode' | 'inlineCode' | 'paren' | 'bracket' | 'dollar' | 'dollarDollar';
  let mode: Mode = 'normal';
  let fenceMarker = ''; // Current fenced code block fence (for example ``` or ~~~)

  while (i < len) {
    const ch = text[i];

    if (mode === 'fencedCode') {
      // Look for the closing fence
      if (ch === '\n') {
        // Line start may carry 0-3 spaces before the fenceMarker
        // Simplification: look for \n[ \t]{0,3}fenceMarker
        const rest = text.slice(i + 1);
        const m = new RegExp(`^[ \\t]{0,3}${fenceMarker[0] === '`' ? '`' : '~'}{${fenceMarker.length},}[ \\t]*(?=\\n|$)`).exec(rest);
        if (m) {
          i += 1 + m[0].length;
          mode = 'normal';
          continue;
        }
      }
      i++;
      continue;
    }

    if (mode === 'inlineCode') {
      // Look for the closing backticks (same length)
      const closeRe = new RegExp(`${fenceMarker.replace(/`/g, '\\`')}`);
      const idxClose = text.indexOf(fenceMarker, i);
      if (idxClose === -1 || text.slice(i, idxClose).includes('\n')) {
        // Unclosed or spanning lines: treat it as closed here and drop the inline code view
        mode = 'normal';
        continue;
      }
      i = idxClose + fenceMarker.length;
      mode = 'normal';
      // Avoids an unused warning
      void closeRe;
      continue;
    }

    if (mode === 'paren') {
      // Look for \) without crossing a line
      if (ch === '\n') {
        // It spans lines, so treat it as unclosed; the opening position was already recorded as the tail start
        // and the `\(` is not valid inline math, so fall back to normal
        mode = 'normal';
        lastOpenStart = -1;
        i++;
        continue;
      }
      if (ch === '\\' && text[i + 1] === ')') {
        i += 2;
        mode = 'normal';
        lastOpenStart = -1;
        continue;
      }
      i++;
      continue;
    }

    if (mode === 'bracket') {
      // Look for \], which may span lines
      if (ch === '\\' && text[i + 1] === ']') {
        i += 2;
        mode = 'normal';
        lastOpenStart = -1;
        continue;
      }
      i++;
      continue;
    }

    if (mode === 'dollarDollar') {
      // Look for the next $$
      if (ch === '$' && text[i + 1] === '$') {
        i += 2;
        mode = 'normal';
        lastOpenStart = -1;
        continue;
      }
      i++;
      continue;
    }

    if (mode === 'dollar') {
      // Look for the closing $ (no line break allowed)
      if (ch === '\n') {
        mode = 'normal';
        lastOpenStart = -1;
        i++;
        continue;
      }
      if (ch === '\\' && text[i + 1] === '$') {
        // An escaped $ does not close it
        i += 2;
        continue;
      }
      if (ch === '$') {
        i++;
        mode = 'normal';
        lastOpenStart = -1;
        continue;
      }
      i++;
      continue;
    }

    // mode === 'normal'
    // Match fenced code first (at a line start)
    if (ch === '\n' || i === 0) {
      const start = ch === '\n' ? i + 1 : i;
      const slice = text.slice(start);
      const fenceMatch = /^[ \t]{0,3}(`{3,}|~{3,})/.exec(slice);
      if (fenceMatch) {
        // Entering a fenced code block
        i = start + fenceMatch[0].length;
        fenceMarker = fenceMatch[1];
        mode = 'fencedCode';
        continue;
      }
    }

    // inline code
    if (ch === '`') {
      // Count the backtick run length
      let j = i;
      while (j < len && text[j] === '`') j++;
      fenceMarker = text.slice(i, j);
      i = j;
      mode = 'inlineCode';
      continue;
    }

    // \( inline math
    if (ch === '\\' && text[i + 1] === '(') {
      lastOpenStart = i;
      i += 2;
      mode = 'paren';
      continue;
    }

    // \[ block math
    if (ch === '\\' && text[i + 1] === '[') {
      lastOpenStart = i;
      i += 2;
      mode = 'bracket';
      continue;
    }

    // $$ block math
    if (ch === '$' && text[i + 1] === '$') {
      lastOpenStart = i;
      i += 2;
      mode = 'dollarDollar';
      continue;
    }

    // Single $ inline math: requires a non-whitespace character right after and no backslash escape
    if (ch === '$' && text[i - 1] !== '\\') {
      const next = text[i + 1];
      // A $ followed by a digit or whitespace is often currency, so detection stays rough. The streaming
      // strategy is conservative: anything read as an opening that never closes is split off as the tail.
      // A misread costs a short tail split, which is better than flickering.
      if (next && next !== ' ' && next !== '\n' && next !== '$') {
        lastOpenStart = i;
        i++;
        mode = 'dollar';
        continue;
      }
    }

    i++;
  }

  // Scan finished
  if (mode === 'paren' || mode === 'bracket' || mode === 'dollar' || mode === 'dollarDollar') {
    // Unclosed, so split off the tail
    if (lastOpenStart >= 0) {
      return {
        closed: text.slice(0, lastOpenStart),
        tail: text.slice(lastOpenStart),
      };
    }
  }

  return { closed: text, tail: '' };
}
