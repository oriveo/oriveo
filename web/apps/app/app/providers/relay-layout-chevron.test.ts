import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';

/**
 * Layout gate (collapse indicator chevrons): in the relay family pages and cross-check panels,
 * a collapsible group / row's chevron points in the text direction when collapsed (flips in RTL) and down when expanded; a down chevron + rotation must not be used for collapsed / expanded.
 */

const ROOT = process.cwd();
const SCOPE_DIRS = ['app/providers/[providerId]', 'app/providers/new', 'app/providers/relay'];
const SCOPE_FILES = ['components/chat/CrosscheckSheet.tsx', 'components/chat/CrosscheckSheet.module.css'];
/** Flipping a menu / popup trigger up and down is menu semantics, not a collapse indicator. */
const MENU_ROTATE_SELECTORS = [".modelTrigger[aria-expanded='true'] .modelChevron"];

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(path.join(ROOT, dir))) {
    const rel = path.posix.join(dir, name);
    if (statSync(path.join(ROOT, rel)).isDirectory()) out.push(...walk(rel));
    else if (/\.(tsx|css)$/.test(name) && !/\.test\.tsx$/.test(name)) out.push(rel);
  }
  return out;
}

const files = [...SCOPE_DIRS.flatMap(walk), ...SCOPE_FILES];
const read = (file: string) => readFileSync(path.join(ROOT, file), 'utf8');

/** CSS rule: selector + declaration body (does not handle selector prefixes inside nested @media; enough for this use). */
function cssRules(source: string): Array<{ selector: string; body: string }> {
  const rules: Array<{ selector: string; body: string }> = [];
  const re = /([^{}]+)\{([^{}]*)\}/g;
  for (let match = re.exec(source); match; match = re.exec(source)) {
    rules.push({ selector: match[1]!.replace(/\/\*[\s\S]*?\*\//g, '').trim(), body: match[2]! });
  }
  return rules;
}

describe('RL2-LAYOUT-CHEVRON-01 collapse chevron direction', () => {
  it('RL2-LAYOUT-CHEVRON-01 tsx: a down chevron does not flip with the expanded state, and no inline rotate is written in components', () => {
    const problems: string[] = [];
    for (const file of files.filter((item) => item.endsWith('.tsx'))) {
      const source = read(file);
      for (const match of source.matchAll(/<(ChevronDown|CaretDown)\b[^>]*?\bdata-(open|expanded|collapsed)=\{(?!false\})/g)) {
        problems.push(`${file}: ${match[0].replace(/\s+/g, ' ')}`);
      }
      if (/rotate\(/.test(source)) problems.push(`${file}: inline rotate(`);
    }
    expect(problems).toEqual([]);
  });

  it('RL2-LAYOUT-CHEVRON-01 css: no rotate(180deg) / rotate(-90deg) for collapsing; chevron classes that rotate(90deg) when expanded must have an :dir(rtl) flip', () => {
    const problems: string[] = [];
    for (const file of files.filter((item) => item.endsWith('.css'))) {
      const rules = cssRules(read(file));
      for (const rule of rules) {
        if (/rotate\((180deg|-90deg)\)/.test(rule.body) && !MENU_ROTATE_SELECTORS.includes(rule.selector)) {
          problems.push(`${file}: ${rule.selector} uses a rotated down chevron`);
        }
        const expanded = /^\.([\w-]+)\[data-(expanded|open)='true'\]$/.exec(rule.selector);
        if (expanded && /rotate\(90deg\)/.test(rule.body)) {
          const cls = expanded[1]!;
          const rtl = rules.some((other) => other.selector === `.${cls}:dir(rtl)` && /scaleX\(-1\)/.test(other.body));
          if (!rtl) problems.push(`${file}: .${cls} collapsed state lacks the :dir(rtl) flip`);
        }
      }
    }
    expect(problems).toEqual([]);
    // Model library groups swap icons (right / down) rather than rotate: the collapsed right chevron also needs the RTL flip.
    expect(read('app/providers/[providerId]/ModelBrowser.module.css'))
      .toMatch(/\.groupChevron:not\(\[data-expanded\]\):dir\(rtl\)\s*\{\s*transform: scaleX\(-1\);/);
  });
});
