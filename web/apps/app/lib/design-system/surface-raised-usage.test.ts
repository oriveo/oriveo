/**
 * --o-surface-raised is a raised surface (menu, popover, dialog, floating card, selected segment thumb).
 * In light mode it is opaque white (light-roles surfaceRaised). Hover / selected backgrounds use
 * --o-surface-hover and secondary fills (skeletons, secondary buttons, badges, icon plates, inset rows)
 * use --o-fill-muted; before all three shared the light #F4F4F5 of raised.
 *
 * Scans apps/app and packages/ui sources (tests and variables.css excluded) and requires every
 * remaining reference to be in ALLOWED. One case per file family so each family can land on its own.
 */

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { describe, expect, it } from 'vitest';

const APP_ROOT = process.cwd();
const WEB_ROOT = join(APP_ROOT, '../..');
const TOKEN = '--o-surface-raised';
const SKIP_DIRS = new Set(['node_modules', '.git']);

/** `path|selector` for CSS, `path` for TS / TSX (any number of references). Paths are relative to the Web workspace root. */
const ALLOWED = new Set<string>([
  // app pages
  'apps/app/app/settings/backup/BackupPage.module.css|.previewCard',
  'apps/app/app/providers/new/ProviderCard.module.css|.customEntry',
  // Hover tints the entry's own raised surface; plain --o-surface-hover is invisible on it in light mode.
  'apps/app/app/providers/new/ProviderCard.module.css|.customEntry:hover',
  'apps/app/app/providers/[providerId]/components/RelayEditConnection.module.css|.addMenu',
  'apps/app/app/providers/[providerId]/components/RelayCatalogParts.module.css|.moreMenu',
  'apps/app/app/welcome/LocaleMenu.module.css|.menu',
  'apps/app/app/settings/context/ContextSettingsPage.module.css|.segmentSelected',
  'apps/app/app/settings/theme/ThemeSettings.module.css|.segmentOn',
  // skills family
  'apps/app/app/skills/edit/SkillEditPage.module.css|.tipPopover',
  // components
  'apps/app/components/sidebar/CreateFolderDialog.tsx',
  'apps/app/components/sidebar/FolderColorPicker.tsx',
  'apps/app/components/chat/MessageBubble.module.css|.generatedImageCard',
  'apps/app/components/chat/QuoteContextChip.module.css|.preview',
  'apps/app/components/chat/SearchErrorCard.module.css|.card',
  'apps/app/components/providers/RelaySecurityModeControl.module.css|.panel',
  'apps/app/components/generation/AdvancedSettingsList.module.css|.card',
  "apps/app/components/generation/AdvancedSettingsList.module.css|.segmented button[aria-checked='true']",
  'apps/app/components/generation/AdditionalBodyEditor.module.css|.card',
  'apps/app/lib/design-system/semantic-text-contrast.ts',
]);

type Family = 'pages' | 'skills' | 'components';

function familyOf(path: string): Family {
  if (path.startsWith('apps/app/app/skills/') || path.startsWith('apps/app/components/skills/')) return 'skills';
  if (path.startsWith('apps/app/app/')) return 'pages';
  return 'components';
}

function walk(dir: string, out: string[]): void {
  for (const name of readdirSync(dir)) {
    if (SKIP_DIRS.has(name) || name.startsWith('.next') || name.startsWith('out')) continue;
    const full = join(dir, name);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (/\.(css|tsx?)$/.test(name) && !/\.test\.tsx?$/.test(name) && name !== 'variables.css') out.push(full);
  }
}

/** Selector of the rule enclosing line `index` (comma-continued selector lines joined). */
function selectorAt(lines: string[], index: number): string {
  for (let i = index; i >= 0; i -= 1) {
    if (!lines[i].includes('{')) continue;
    let selector = lines[i].split('{')[0].trim();
    for (let j = i; j > 0 && lines[j - 1].trimEnd().endsWith(','); j -= 1) selector = `${lines[j - 1].trim()} ${selector}`;
    return selector;
  }
  return '?';
}

interface Hit { key: string; where: string; family: Family }

function hits(): Hit[] {
  const files: string[] = [];
  walk(join(WEB_ROOT, 'apps/app'), files);
  walk(join(WEB_ROOT, 'packages/ui/src'), files);
  const found: Hit[] = [];
  for (const file of files) {
    const text = readFileSync(file, 'utf8');
    if (!text.includes(TOKEN)) continue;
    const path = relative(WEB_ROOT, file);
    const lines = text.split('\n');
    lines.forEach((line, i) => {
      if (!line.includes(TOKEN)) return;
      const key = path.endsWith('.css') ? `${path}|${selectorAt(lines, i)}` : path;
      found.push({ key, where: `${path}:${i + 1} ${key.split('|')[1] ?? ''}`.trim(), family: familyOf(path) });
    });
  }
  return found;
}

describe('--o-surface-raised is only used for raised surfaces', () => {
  const all = hits();
  for (const family of ['pages', 'skills', 'components'] as const) {
    it(`${family}: hover / selected use --o-surface-hover, secondary fills use --o-fill-muted`, () => {
      const extra = all.filter((h) => h.family === family && !ALLOWED.has(h.key)).map((h) => h.where);
      const present = new Set(all.map((h) => h.key));
      const stale = [...ALLOWED].filter((k) => familyOf(k.split('|')[0]) === family && !present.has(k));
      // extra: migrate to --o-surface-hover (hover / selected) or --o-fill-muted (secondary fill).
      // stale: an ALLOWED raised surface no longer references --o-surface-raised.
      expect({ extra, stale }).toEqual({ extra: [], stale: [] });
    });
  }
});
