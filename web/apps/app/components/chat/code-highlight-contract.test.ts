import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { highlightCode } from '../../lib/markdown/highlight-setup';

/**
 * Code highlighting "Oriveo Code": the web uses highlight.js.
 * This test reads the shared fixture code-highlight.v1.json at run time and asserts that
 * 1. the 12 roles + diff line backgrounds in the light / dark sections of variables.css equal the fixture value for value, and no dark palette section overrides the code colors;
 * 2. every classifyCases entry, run through the production highlightCode and with class names swapped for roles using the selectors in highlight-theme.css, matches the expectation;
 * 3. highlight-theme.css has no slanted text.
 */
const REPO_ROOT = join(process.cwd(), '../../..');
const contract = JSON.parse(
  readFileSync(join(REPO_ROOT, 'shared/theme-contracts/code-highlight.v1.json'), 'utf8'),
) as {
  roles: string[];
  light: Record<string, unknown>;
  dark: Record<string, unknown>;
  classifyCases: { name: string; language: string; code: string; expect: [string, string][] }[];
};
const VARIABLES_CSS = readFileSync(join(REPO_ROOT, 'web/packages/ui/src/tokens/variables.css'), 'utf8');
const THEME_CSS = readFileSync(join(process.cwd(), 'components/chat/highlight-theme.css'), 'utf8');

/** Role name to CSS variable suffix (diffAdd to diff-add). */
const kebab = (role: string) => role.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`);
const camel = (name: string) => name.replace(/-([a-z])/g, (_, c: string) => c.toUpperCase());

function block(selector: string): string {
  const start = VARIABLES_CSS.indexOf(`${selector} {`);
  expect(start, selector).toBeGreaterThanOrEqual(0);
  const open = VARIABLES_CSS.indexOf('{', start);
  return VARIABLES_CSS.slice(open + 1, VARIABLES_CSS.indexOf('}', open));
}

function declaration(body: string, name: string): string | undefined {
  return new RegExp(`--o-${name}:\\s*([^;]+);`).exec(body)?.[1].trim();
}

function rgba(line: unknown): string {
  const { from, alpha } = line as { from: string; alpha: number };
  const n = parseInt(from.slice(1), 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
}

describe('Oriveo Code color values (variables.css == code-highlight.v1.json)', () => {
  const segments = { light: block(":root,\n[data-theme='light']"), dark: block("[data-theme='dark']") } as const;

  it.each(['light', 'dark'] as const)('the %s section has the 12 roles and diff line backgrounds equal value for value', (mode) => {
    const body = segments[mode];
    expect(contract.roles).toHaveLength(12);
    for (const role of contract.roles) {
      expect(declaration(body, `code-${kebab(role)}`)?.toUpperCase(), `${mode}.${role}`).toBe(
        String(contract[mode][role]).toUpperCase(),
      );
    }
    expect(declaration(body, 'code-diff-add-line')).toBe(rgba(contract[mode].diffAddLine));
    expect(declaration(body, 'code-diff-delete-line')).toBe(rgba(contract[mode].diffDeleteLine));
  });

  it('the old builtin / attr variables are removed', () => {
    expect(VARIABLES_CSS).not.toMatch(/--o-code-(builtin|attr):/);
  });

  it('no dark palette section overrides the code colors (only code-bg / code-header-bg change)', () => {
    const paletteBlocks = [...VARIABLES_CSS.matchAll(/\[data-theme='dark'\]\[data-palette='[^']+'\] \{([^}]*)\}/g)];
    expect(paletteBlocks.length).toBeGreaterThan(0);
    for (const [, body] of paletteBlocks) {
      for (const role of contract.roles) {
        expect(declaration(body, `code-${kebab(role)}`)).toBeUndefined();
      }
    }
  });
});

interface ColorRule {
  /** Ancestor language class, e.g. language-diff; unrestricted when absent */
  ancestor?: string;
  classes: string[];
  role: string;
  specificity: number;
  order: number;
}

/** Extract every `selector { color: var(--o-code-*) }` rule from highlight-theme.css. */
function colorRules(): ColorRule[] {
  const css = THEME_CSS.replace(/\/\*[\s\S]*?\*\//g, '');
  const rules: ColorRule[] = [];
  for (const [, selectorList, body] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const color = /(?:^|[;\s])color:\s*var\(--o-code-([a-z-]+)\)/.exec(body);
    if (!color) continue;
    for (const selector of selectorList.split(',')) {
      const parts = selector.trim().split(/\s+/);
      expect(parts.length, selector).toBeLessThanOrEqual(2);
      const compound = parts[parts.length - 1].split('.').filter(Boolean);
      const ancestor = parts.length === 2 ? parts[0].replace(/^\./, '') : undefined;
      rules.push({
        ancestor,
        classes: compound,
        role: camel(color[1]),
        specificity: compound.length + (ancestor ? 1 : 0),
        order: rules.length,
      });
    }
  }
  return rules;
}

/** The highest-specificity rule the element itself matches (the later one wins on a tie), simulating the CSS cascade. */
function matchedRole(el: Element, rules: ColorRule[]): string | undefined {
  let best: ColorRule | undefined;
  for (const rule of rules) {
    if (!rule.classes.every((c) => el.classList.contains(c))) continue;
    if (rule.ancestor && !el.closest(`.${rule.ancestor}`)) continue;
    if (!best || rule.specificity > best.specificity || (rule.specificity === best.specificity && rule.order > best.order)) {
      best = rule;
    }
  }
  return best?.role;
}

/** Per-character role: walk up from the text node to the first element that matches a rule (classes that match nothing inherit the parent color, ending at .hljs = text). */
function charRoles(code: string, language: string, rules: ColorRule[]): { text: string; roles: string[] } {
  const host = document.createElement('code');
  host.className = `hljs language-${language}`;
  host.innerHTML = highlightCode(code, language);
  const roles: string[] = [];
  let text = '';
  const walker = document.createTreeWalker(host, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    let role: string | undefined;
    for (let el: Element | null = node.parentElement; el && !role; el = el === host ? null : el.parentElement) {
      role = matchedRole(el, rules);
    }
    const value = node.textContent ?? '';
    text += value;
    for (let i = 0; i < value.length; i++) roles.push(role ?? 'none');
  }
  return { text, roles };
}

/**
 * Cases that highlight.js's grammar definitions cannot distinguish (ruled outside the fixture: they take no other role's color and fall to text):
 * Swift function call names, unclassed parentheses / commas / colons, and members after `.` all get no class from hljs.
 */
const HLJS_TEXT_FALLBACK: Record<string, string[]> = {
  swift_call_and_assignment: ['wcag', '(', ',', ')'],
  swift_type_and_member: [':', 'accentColor'],
  python_decorator_def_member: ['min_ratio'],
};

describe('classifyCases: hljs class names are mapped to Oriveo Code roles through highlight-theme.css', () => {
  const rules = colorRules();

  it('the mapping references only the 12 roles in the fixture', () => {
    for (const rule of rules) expect(contract.roles).toContain(rule.role);
  });

  it.each(contract.classifyCases.map((c) => [c.name, c] as const))('%s', (_name, c) => {
    const { text, roles } = charRoles(c.code, c.language, rules);
    expect(text).toBe(c.code);
    const fallback = HLJS_TEXT_FALLBACK[c.name] ?? [];
    for (const piece of fallback) expect(c.expect.map(([t]) => t)).toContain(piece);
    for (const [piece, role] of c.expect) {
      const index = c.code.indexOf(piece);
      expect(index, piece).toBeGreaterThanOrEqual(0);
      const actual = [...new Set(roles.slice(index, index + piece.length))];
      if (fallback.includes(piece)) {
        expect(actual.length === 1 && [role, 'text'].includes(actual[0]), `${piece} → ${actual.join('/')}`).toBe(true);
      } else {
        expect(actual, piece).toEqual([role]);
      }
    }
  });
});

/** Extra cases for the web (not in the shared fixture): hljs also emits .hljs-variable in languages without $ variables, where an ordinary identifier = body color. */
describe('.hljs-variable reads as a property only in languages with $ variables', () => {
  const rules = colorRules();
  const roleOf = (code: string, language: string, piece: string, from = 0) => {
    const { roles } = charRoles(code, language, rules);
    const index = code.indexOf(piece, from);
    return [...new Set(roles.slice(index, index + piece.length))];
  };

  it('the s in Rust `let s = 1;` is text', () => {
    expect(roleOf('let s = 1;', 'rust', 's', 4)).toEqual(['text']);
  });

  it('bash $HOME is property, and PHP $this is still keyword', () => {
    expect(roleOf('echo $HOME', 'bash', '$HOME')).toEqual(['property']);
    expect(roleOf('<?php $this->a = $b;', 'php', '$this')).toEqual(['keyword']);
    expect(roleOf('<?php $this->a = $b;', 'php', '$b')).toEqual(['property']);
  });
});

describe('highlight-theme.css', () => {
  it('no slanted text (CJK comments would get a synthesized slant)', () => {
    expect(THEME_CSS).not.toMatch(/italic/i);
  });

  it('diff added / deleted lines get a full-line background', () => {
    const css = THEME_CSS.replace(/\/\*[\s\S]*?\*\//g, '');
    expect(css).toMatch(/\.hljs-addition\s*\{[^}]*background-color:\s*var\(--o-code-diff-add-line\)/);
    expect(css).toMatch(/\.hljs-deletion\s*\{[^}]*background-color:\s*var\(--o-code-diff-delete-line\)/);
    expect(css).toMatch(/\.hljs-addition,\s*\.hljs-deletion\s*\{[^}]*display:\s*inline-block;[^}]*min-width:\s*100%/);
  });
});
