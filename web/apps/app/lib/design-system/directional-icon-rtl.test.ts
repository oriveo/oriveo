/**
 * Directional arrows meaning forward / back / next level flip with the layout under RTL.
 *
 * Scans non-test tsx under apps/app for JSX of ChevronRight/Left, ArrowRight/Left, CaretRight/Left from lucide / phosphor / the app's own components/icons
 * (including phosphor's *Icon aliases): the same element's className must contain the global utility class `rtl-mirror`,
 * or the referenced CSS module class must have a rule with `:dir(rtl)` (or the legacy `[dir='rtl']`) in the corresponding css (component-level flipping; rotate-to-expand ones manage themselves via that rule).
 * Not a blanket rule on lucide class names: it would stack with existing component-level flips and rotate-to-expand, flipping them back.
 */

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

const APP_ROOT = process.cwd();
const ICON_NAMES = ['ChevronRight', 'ChevronLeft', 'ArrowRight', 'ArrowLeft', 'CaretRight', 'CaretLeft'];
const ICON_PACKAGES = ['lucide-react', '@phosphor-icons/react'];
/** The app's own icon module (components/icons): directional icons are in scope regardless of source. */
const LOCAL_ICON_MODULE = join(APP_ROOT, 'components/icons');

function isIconSource(file: string, specifier: string): boolean {
  if (ICON_PACKAGES.includes(specifier)) return true;
  if (!specifier.startsWith('.')) return false;
  const target = resolve(dirname(join(APP_ROOT, file)), specifier).replace(/\/index(\.tsx?)?$/, '');
  return target === LOCAL_ICON_MODULE;
}
const UTILITY_CLASS = 'rtl-mirror';

function sourceTsxFiles(): string[] {
  return execFileSync(
    'git',
    ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '*.tsx'],
    { cwd: APP_ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  ).split('\0').filter((file) => file && !/\.test\.tsx$/.test(file) && existsSync(join(APP_ROOT, file)));
}

/** Local names of directional icons this file imports from the two icon packages (including `X as Y` aliases). */
function importedDirectionalIcons(file: string, source: string): Set<string> {
  const names = new Set<string>();
  const importPattern = /import\s*(?:type\s*)?\{([^}]*)\}\s*from\s*['"]([^'"]+)['"]/g;
  for (const match of source.matchAll(importPattern)) {
    if (!isIconSource(file, match[2]!)) continue;
    for (const raw of match[1]!.split(',')) {
      const [imported, local] = raw.trim().split(/\s+as\s+/);
      if (!imported) continue;
      const base = imported.replace(/Icon$/, '');
      if (ICON_NAMES.includes(base)) names.add((local ?? imported).trim());
    }
  }
  return names;
}

/** `import styles from './X.module.css'` -> { styles: absolute path }. */
function cssModuleImports(file: string, source: string): Map<string, string> {
  const map = new Map<string, string>();
  for (const match of source.matchAll(/import\s+(\w+)\s+from\s+['"]([^'"]+\.module\.css)['"]/g)) {
    map.set(match[1]!, resolve(dirname(join(APP_ROOT, file)), match[2]!));
  }
  return map;
}

/** In a selector, the same item names the class and carries an RTL condition (`:dir(rtl)`, or the legacy `[dir='rtl']` ancestor form). */
function cssHasRtlRule(cssPath: string, className: string): boolean {
  const css = readFileSync(cssPath, 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
  const escaped = className.replace(/[$()*+.?[\\\]^{|}-]/g, '\\$&');
  const classPattern = new RegExp(`\\.${escaped}(?![\\w-])`);
  const rtlPattern = /:dir\(rtl\)|\[dir=['"]?rtl['"]?\]/;
  return [...css.matchAll(/([^{}]+)\{/g)].some((rule) => rule[1]!.split(',').some((selector) => (
    classPattern.test(selector) && rtlPattern.test(selector)
  )));
}

/** The original className attribute text: braces are cut by pairing, so `${...}` inside template strings does not truncate early. */
function classNameAttr(attrs: string): string {
  const start = attrs.search(/className=/);
  if (start < 0) return '';
  let index = start + 'className='.length;
  const quote = attrs[index];
  if (quote === '"' || quote === "'") return attrs.slice(index, attrs.indexOf(quote, index + 1) + 1);
  let depth = 0;
  const from = index;
  for (; index < attrs.length; index += 1) {
    if (attrs[index] === '{') depth += 1;
    if (attrs[index] === '}') depth -= 1;
    if (depth === 0) break;
  }
  return attrs.slice(from, index + 1);
}

function utilityDefined(): boolean {
  const css = readFileSync(join(APP_ROOT, 'app/globals.css'), 'utf8');
  return new RegExp(`\\.${UTILITY_CLASS}(?![\\w-])[^{},]*:dir\\(rtl\\)`).test(css);
}

interface Offender { location: string; tag: string }

function directionalIconOffenders(): Offender[] {
  const offenders: Offender[] = [];
  const utilityOk = utilityDefined();
  for (const file of sourceTsxFiles()) {
    const source = readFileSync(join(APP_ROOT, file), 'utf8');
    const icons = importedDirectionalIcons(file, source);
    if (icons.size === 0) continue;
    const modules = cssModuleImports(file, source);
    const tagPattern = new RegExp(`<(${[...icons].join('|')})\\b([\\s\\S]*?)\\/>`, 'g');
    for (const match of source.matchAll(tagPattern)) {
      const attrs = match[2]!;
      const line = source.slice(0, match.index).split('\n').length;
      const classAttr = classNameAttr(attrs);
      const viaUtility = utilityOk && new RegExp(`(^|[^\\w-])${UTILITY_CLASS}(?![\\w-])`).test(classAttr);
      const viaModule = [...classAttr.matchAll(/(\w+)\.([A-Za-z_][\w-]*)/g)].some(([, ident, cls]) => {
        const cssPath = modules.get(ident!);
        return cssPath !== undefined && cssHasRtlRule(cssPath, cls!);
      });
      if (!viaUtility && !viaModule) offenders.push({ location: `${file}:${line}`, tag: match[1]! });
    }
  }
  return offenders;
}

describe('RTL mirroring of directional arrows, repo-wide gate', () => {
  it('every directional icon has rtl-mirror or a :dir(rtl) rule on its module class', () => {
    expect(directionalIconOffenders()).toEqual([]);
  });

  it('the gate itself recognizes icons (guards against a false green from an empty scan)', () => {
    const scanned = sourceTsxFiles().filter((file) => (
      importedDirectionalIcons(file, readFileSync(join(APP_ROOT, file), 'utf8')).size > 0
    ));
    expect(scanned.length).toBeGreaterThan(10);
  });
});
